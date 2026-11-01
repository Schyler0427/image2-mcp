import Foundation
import CryptoKit
import Darwin

private enum TestFailure: Error, CustomStringConvertible, LocalizedError {
    case failed(String)
    var description: String { if case let .failed(message) = self { return message }; return "test failure" }
    var errorDescription: String? { description }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.failed(message) }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TestFailure.failed(message)
}

private final class PackageFixture {
    let root: URL
    let resources: URL
    let home: URL
    let architecture: String
    let package: URL
    var entries: [[String: Any]] = []

    init(script: String) throws {
        architecture = try NativeArchitecture.current()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("image2-core-fixture-" + UUID().uuidString)
        resources = root.appendingPathComponent("Resources")
        home = root.appendingPathComponent("HOME")
        package = resources.appendingPathComponent("packages/" + architecture)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try add("install-offline.sh", text: script)
        try add("payload/fixture.txt", text: "isolated package fixture\n")
        try saveManifest()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func add(_ path: String, text: String) throws {
        let data = Data(text.utf8)
        let url = package.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        entries.append(["path": "packages/" + architecture + "/" + path,
                        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "size": data.count])
    }

    func saveManifest(version: String = "0.4.0") throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "files": entries], options: [.sortedKeys])
        try data.write(to: resources.appendingPathComponent("resource-manifest.json"))
    }

    func install(_ credentials: LauncherCredentials = LauncherCredentials(image2Key: "fixture-image-key", geminiKey: "fixture-gemini-key"), expectedVersion: String? = "0.4.0", status: @escaping (String) -> Void = { _ in }) throws -> LauncherInstallationResult {
        try OfflineInstaller(resourcesURL: resources, homeURL: home, expectedVersion: expectedVersion).install(credentials: credentials, status: status)
    }
}

@main
private struct InstallerCoreTests {
    static func main() {
        let groups: [(String, () throws -> Void)] = [
            ("credentials", credentials), ("architecture", architecture),
            ("process isolation", processIsolation), ("optional provider stdin", optionalProviderStdin), ("result/redaction", resultAndRedaction),
            ("resource refusal", resourceRefusal), ("resource preflight", resourcePreflight), ("package versions", packageVersions),
            ("bounded drain", boundedDrain), ("transaction wait", waitsForTransaction),
            ("safe diagnostics", safeDiagnostics)
        ]
        for (name, test) in groups {
            do { try test() } catch {
                fputs("FAIL: InstallerCoreTests [\(name)]: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        print("PASS: InstallerCoreTests (credentials, architecture, process isolation, result/redaction, resource refusal, package versions, bounded drain, transaction wait)")
    }

    static func credentials() throws {
        let credentials = LauncherCredentials(image2Key: "image-test", geminiKey: "gemini-test")
        try credentials.validate()
        try expect(credentials.stdinData == Data("image-test\ngemini-test\n".utf8), "stdin preserves separate provider keys")
        for (image2, gemini, expected) in [("image-only", "", "image-only\n\n"), ("", "gemini-only", "\ngemini-only\n"), (" \t", "gemini-only", "\ngemini-only\n"), ("image-only", "　 \t", "image-only\n\n")] {
            let optional = LauncherCredentials(image2Key: image2, geminiKey: gemini)
            try optional.validate()
            try expect(optional.stdinData == Data(expected.utf8), "one configured provider keeps exactly two stdin lines with no credential fallback")
        }
        for (image2, gemini) in [("", ""), (" \t", "　")] {
            try expectThrows("at least one provider key is required") { try LauncherCredentials(image2Key: image2, geminiKey: gemini).validate() }
        }
        for invalid in ["line\nbreak", "line\rbreak", "line\r\nbreak", "nul\0byte", "\n", "\r", " \t\0", String(repeating: " ", count: 1025), String(repeating: "x", count: 1025), String(repeating: "界", count: 342)] {
            try expectThrows("Image2 rejects invalid key") { try LauncherCredentials(image2Key: invalid, geminiKey: "valid").validate() }
            try expectThrows("Gemini rejects invalid key") { try LauncherCredentials(image2Key: "valid", geminiKey: invalid).validate() }
            try expectThrows("provided invalid Image2 key is refused even without Gemini") { try LauncherCredentials(image2Key: invalid, geminiKey: "").validate() }
            try expectThrows("provided invalid Gemini key is refused even without Image2") { try LauncherCredentials(image2Key: "", geminiKey: invalid).validate() }
        }
        try LauncherCredentials(image2Key: String(repeating: "x", count: 1024), geminiKey: " 测试-key ").validate()
        try expect(LauncherCredentials(image2Key: " image-key ", geminiKey: "").stdinData == Data(" image-key \n\n".utf8), "nonblank key bytes are preserved")
    }

    static func resourcePreflight() throws {
        let fixture = try PackageFixture(script: "exit 99\n")
        try OfflineInstaller.verifyResources(at: fixture.resources, expectedVersion: "0.4.0")
        try expect(FileManager.default.contentsOfDirectory(atPath: fixture.home.path).isEmpty,
                   "credential-free preflight never launches installer or writes user configuration")
        try expectThrows("preflight refuses mismatched bundle version") {
            try OfflineInstaller.verifyResources(at: fixture.resources, expectedVersion: "999.0.0")
        }
        try Data("tampered".utf8).write(to: fixture.package.appendingPathComponent("payload/fixture.txt"))
        try expectThrows("preflight refuses damaged bundled bytes") {
            try OfflineInstaller.verifyResources(at: fixture.resources, expectedVersion: "0.4.0")
        }
    }

    static func safeDiagnostics() throws {
        for (line, expectedCode) in [
            ("error: unsupported Image2 TOML table header", "INSTALL_CONFIGURATION"),
            ("error: existing archive target has no valid managed marker", "INSTALL_EXISTING_TARGET"),
            ("error: Permission denied", "INSTALL_PERMISSION"),
            ("error: offline package SHA-256 mismatch", "INSTALL_RESOURCES"),
            ("error: MCP handshake verification failed", "INSTALL_VERIFICATION"),
            ("unrecognized failure", "INSTALL_PROCESS")
        ] {
            let fixture = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf '%s\\n' '\(line)'\nprintf '%s\\n' \"$first\"\nexit 7\n")
            do {
                _ = try fixture.install()
                throw TestFailure.failed("failed process accepted")
            } catch let error as LauncherCoreError {
                try expect(error.diagnostic?.code == expectedCode, "known failure classified as \(expectedCode)")
                try expect(error.exitStatus == 7, "numeric exit status retained")
                try expect(!error.localizedDescription.contains("fixture-image-key"), "debug output stays redacted")
                try expect(!(error.diagnostic?.summary ?? "").contains(line), "display uses static summaries")
            }
        }
        let missingResources = URL(fileURLWithPath: "/missing-image2-test-resources-\(UUID().uuidString)")
        let fixture = try PackageFixture(script: "exit 0\n")
        do {
            _ = try OfflineInstaller(resourcesURL: missingResources, homeURL: fixture.home).install(credentials: LauncherCredentials(image2Key: "fixture-image-key", geminiKey: ""), status: { _ in })
            throw TestFailure.failed("missing resources accepted")
        } catch let error as LauncherCoreError {
            try expect(error.diagnostic?.code == "INSTALL_RESOURCES", "resource failure has static diagnostic")
        }
        do {
            _ = try OfflineInstaller(resourcesURL: fixture.resources, homeURL: missingResources).install(credentials: LauncherCredentials(image2Key: "fixture-image-key", geminiKey: ""), status: { _ in })
            throw TestFailure.failed("missing home accepted")
        } catch let error as LauncherCoreError {
            try expect(error.diagnostic?.code == "INSTALL_HOME", "home failure has static diagnostic")
        }
    }

    static func architecture() throws {
        try expect(try NativeArchitecture.current() == "arm64" || NativeArchitecture.current() == "amd64", "native architecture is a package architecture")
        try expect(try NativeArchitecture.resolve(machine: "x86_64", arm64Hardware: true) == "arm64", "Rosetta selects native arm64 package")
        try expect(try NativeArchitecture.resolve(machine: "arm64", arm64Hardware: true) == "arm64", "ARM64 selects arm64")
        try expect(try NativeArchitecture.resolve(machine: "x86_64", arm64Hardware: false) == "amd64", "Intel selects amd64")
        try expectThrows("unsupported hardware fails closed") { _ = try NativeArchitecture.resolve(machine: "i386", arm64Hardware: false) }
        try expect(NativeArchitecture.installerCommand(packageArchitecture: "arm64", processArchitecture: "x86_64") == ["/usr/bin/arch", "-arm64", "/bin/bash", "install-offline.sh"], "Rosetta explicitly launches native ARM shell")
        try expect(NativeArchitecture.installerCommand(packageArchitecture: "arm64", processArchitecture: "arm64") == ["/bin/bash", "install-offline.sh"], "native ARM launch directly runs bash")
        try expect(NativeArchitecture.installerCommand(packageArchitecture: "amd64", processArchitecture: "x86_64") == ["/bin/bash", "install-offline.sh"], "Intel launch directly runs bash")
    }

    static func processIsolation() throws {
        let fixture = try PackageFixture(script: #"""
        set -euo pipefail
        IFS= read -r first
        IFS= read -r second
        [[ "$first" == fixture-image-key && "$second" == fixture-gemini-key && "$#" == 0 ]]
        [[ -z "${LAUNCHER_TEST_INHERITED+x}" && -z "${OPENAI_IMAGE_API_KEY+x}" && -z "${GEMINI_API_KEY+x}" && -z "${BASH_ENV+x}" ]]
        /usr/bin/env > "$HOME/environment.txt"
        /usr/bin/uname -m > "$HOME/shell-architecture.txt"
        pwd > "$HOME/cwd.txt"
        printf '%s\n%s\n' "$first" "$second" > "$HOME/stdin.txt"
        printf '%s\n' "$first"
        printf '%s\n' "$second" >&2
        printf 'Verification: OK\n'
        """#)
        setenv("LAUNCHER_TEST_INHERITED", "must-not-inherit", 1)
        setenv("OPENAI_IMAGE_API_KEY", "dummy-parent-image-key", 1)
        setenv("GEMINI_API_KEY", "dummy-parent-gemini-key", 1)
        let startup = fixture.root.appendingPathComponent("startup.sh")
        try Data("exit 71\n".utf8).write(to: startup)
        setenv("BASH_ENV", startup.path, 1)
        defer { for key in ["LAUNCHER_TEST_INHERITED", "OPENAI_IMAGE_API_KEY", "GEMINI_API_KEY", "BASH_ENV"] { unsetenv(key) } }
        var statuses: [String] = []
        let result = try fixture.install(status: { statuses.append($0) })
        try expect(!result.output.contains("fixture-image-key") && !result.output.contains("fixture-gemini-key"), "stdout/stderr redact both provider values")
        try expect(!statuses.isEmpty && !statuses.joined().contains("fixture-image-key"), "status callbacks contain safe progress only")
        let environment = try String(contentsOf: fixture.home.appendingPathComponent("environment.txt"), encoding: .utf8)
        try expect(environment.contains("HOME=" + fixture.home.path), "child HOME is explicit isolated home")
        try expect(!environment.contains("dummy-parent") && !environment.contains("must-not-inherit"), "no inherited secret environment")
        let input = try String(contentsOf: fixture.home.appendingPathComponent("stdin.txt"), encoding: .utf8)
        try expect(input == "fixture-image-key\nfixture-gemini-key\n", "stdin sends two lines once")
        let shellArchitecture = try String(contentsOf: fixture.home.appendingPathComponent("shell-architecture.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(shellArchitecture == (fixture.architecture == "arm64" ? "arm64" : "x86_64"), "shell architecture matches selected native package, including Rosetta launcher")
        let workingDirectory = try String(contentsOf: fixture.home.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(!workingDirectory.hasPrefix(fixture.resources.path), "package executes from private copy")
        try expect(!FileManager.default.fileExists(atPath: workingDirectory), "private copy is removed after transaction")
        try expect(FileManager.default.fileExists(atPath: fixture.package.appendingPathComponent("payload/fixture.txt").path), "source package remains intact")
    }

    static func optionalProviderStdin() throws {
        let fixture = try PackageFixture(script: #"""
        set -euo pipefail
        IFS= read -r first
        IFS= read -r second
        if IFS= read -r extra; then exit 12; fi
        printf '%s\n%s\n' "$first" "$second" > "$HOME/stdin.txt"
        printf 'Verification: OK\n'
        """#)
        for (image2, gemini, expected) in [("image-only", "", "image-only\n\n"), ("", "gemini-only", "\ngemini-only\n"), ("image-only", " \t", "image-only\n\n"), ("　", "gemini-only", "\ngemini-only\n")] {
            _ = try fixture.install(LauncherCredentials(image2Key: image2, geminiKey: gemini))
            let input = try String(contentsOf: fixture.home.appendingPathComponent("stdin.txt"), encoding: .utf8)
            try expect(input == expected, "subprocess receives optional provider as an empty line without key reuse")
        }
    }

    static func resultAndRedaction() throws {
        let credentials = LauncherCredentials(image2Key: "fixture-token", geminiKey: "fixture-token-tail")
        let fixture = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf '%s %s\\n' \"$second\" \"$first\"\nprintf 'Verification: OK\\n'\n")
        let result = try fixture.install(credentials)
        try expect(!result.output.contains("fixture-token") && !result.output.contains("-tail"), "overlapping provider values redact longest match")
        let crossing = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf 'abcde\\nVerification: OK\\n'\n")
        let crossingResult = try crossing.install(LauncherCredentials(image2Key: "abc", geminiKey: "cde"))
        try expect(!crossingResult.output.contains("abc") && !crossingResult.output.contains("cde") && !crossingResult.output.contains("de\n"), "partially overlapping provider values redact the entire union")
        let marker = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf '%s\\n%s\\nVerification: OK\\n' \"$first\" \"$second\"\n")
        let markerResult = try marker.install(LauncherCredentials(image2Key: "[REDACTED]", geminiKey: "provider-fixture"))
        try expect(!markerResult.output.contains("[REDACTED]"), "replacement marker cannot equal a provider value")
        let unicode = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf '%16380s' ''\nprintf '%s\\n%s\\nVerification: OK\\n' \"$first\" \"$second\"\n")
        let unicodeResult = try unicode.install(LauncherCredentials(image2Key: "界🌿-fixture-key", geminiKey: "other-fixture-key"))
        try expect(!unicodeResult.output.contains("界🌿-fixture-key") && !unicodeResult.output.contains("other-fixture-key"), "UTF-8 keys redact across read boundaries")
        var safeStatuses: [String] = []
        _ = try marker.install(LauncherCredentials(image2Key: "Codex", geminiKey: "安装"), status: { safeStatuses.append($0) })
        try expect(!safeStatuses.joined().contains("Codex") && !safeStatuses.joined().contains("安装"), "status labels also redact complete provider values")
        let invalidUTF8 = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf '\\377\\nVerification: OK\\n'\n")
        let decoded = try invalidUTF8.install(LauncherCredentials(image2Key: "�", geminiKey: "fixture-other"))
        try expect(!decoded.output.contains("�"), "replacement decoding cannot introduce a provider value")
        for script in ["printf 'no verification\\n'\n", "printf 'prefix Verification: OK\\n'\n", "printf 'Verification: OK suffix\\n'\n", "printf 'Verification: OK\\n'; exit 9\n"] {
            let failed = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\n" + script)
            try expectThrows("success needs exit zero and exact verification line") { _ = try failed.install() }
        }
        let failed = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf '%s %s\\n' \"$first\" \"$second\" >&2\nexit 7\n")
        do { _ = try failed.install(credentials); throw TestFailure.failed("failed child must throw") } catch let error as TestFailure { throw error } catch {
            let message = String(describing: error) + error.localizedDescription
            try expect(!message.contains("fixture-token"), "failure errors contain no keys")
        }
    }

    static func resourceRefusal() throws {
        let script = "IFS= read -r first\nIFS= read -r second\ntouch \"$HOME/launched\"\nprintf 'Verification: OK\\n'\n"
        let mutations: [(String, (PackageFixture) throws -> Void)] = [
            ("missing manifest", { try FileManager.default.removeItem(at: $0.resources.appendingPathComponent("resource-manifest.json")) }),
            ("symlink manifest", { fixture in let manifest = fixture.resources.appendingPathComponent("resource-manifest.json"); let outside = fixture.root.appendingPathComponent("manifest.json"); try FileManager.default.moveItem(at: manifest, to: outside); try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside) }),
            ("tampered resource", { try Data("tampered".utf8).write(to: $0.package.appendingPathComponent("payload/fixture.txt")) }),
            ("missing script", { try FileManager.default.removeItem(at: $0.package.appendingPathComponent("install-offline.sh")) }),
            ("symlink file", { fixture in let file = fixture.package.appendingPathComponent("payload/fixture.txt"); try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.package.appendingPathComponent("install-offline.sh")) }),
            ("symlink directory", { fixture in let directory = fixture.package.appendingPathComponent("payload"); let outside = fixture.root.appendingPathComponent("outside"); try FileManager.default.moveItem(at: directory, to: outside); try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside) }),
            ("hardlink file", { fixture in try FileManager.default.linkItem(at: fixture.package.appendingPathComponent("payload/fixture.txt"), to: fixture.root.appendingPathComponent("linked")) }),
            ("path escape", { $0.entries[0]["path"] = "packages/" + $0.architecture + "/../install-offline.sh"; try $0.saveManifest() }),
            ("absolute path", { $0.entries[0]["path"] = "/tmp/install-offline.sh"; try $0.saveManifest() }),
            ("duplicate path", { $0.entries.append($0.entries[0]); try $0.saveManifest() }),
            ("unlisted file", { try Data("extra".utf8).write(to: $0.package.appendingPathComponent("unlisted.sh")) }),
            ("wrong version", { try $0.saveManifest(version: "0.3.0") }),
            ("oversized file declaration", { $0.entries[0]["size"] = 268435457; try $0.saveManifest() }),
            ("bad digest", { $0.entries[0]["sha256"] = String(repeating: "0", count: 64); try $0.saveManifest() }),
            ("oversized manifest", { try Data(repeating: 32, count: 262145).write(to: $0.resources.appendingPathComponent("resource-manifest.json")) })
        ]
        for (name, mutate) in mutations {
            let fixture = try PackageFixture(script: script)
            try mutate(fixture)
            try expectThrows(name + " is rejected") { _ = try fixture.install() }
            try expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("launched").path), name + " is refused before subprocess launch")
        }
        let fixture = try PackageFixture(script: script)
        let alias = fixture.root.appendingPathComponent("resource-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.resources)
        try expectThrows("symlink resource root is refused") { _ = try OfflineInstaller(resourcesURL: alias, homeURL: fixture.home).install(credentials: LauncherCredentials(image2Key: "fixture-a", geminiKey: "fixture-b"), status: { _ in }) }
        for credentials in [LauncherCredentials(image2Key: "", geminiKey: ""), LauncherCredentials(image2Key: "fixture-a", geminiKey: "bad\nkey"), LauncherCredentials(image2Key: "bad\0key", geminiKey: "")] {
            try expectThrows("invalid credentials rejected before launch") { _ = try fixture.install(credentials) }
            try expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("launched").path), "invalid credentials do not reach subprocess")
        }
        let executable = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\n./scripts/helper.sh\n")
        try executable.add("scripts/helper.sh", text: "#!/bin/bash\nprintf 'Verification: OK\\n'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.package.appendingPathComponent("scripts/helper.sh").path)
        for index in 0..<60 { try executable.add("payload/file-\(index).txt", text: "fixture\n") }
        try executable.saveManifest()
        _ = try executable.install()
    }

    static func boundedDrain() throws {
        let fixture = try PackageFixture(script: #"""
        IFS= read -r first
        IFS= read -r second
        /usr/bin/head -c 1048576 /dev/zero | /usr/bin/tr '\0' x
        printf '\n%s\n%s\nVerification: OK\n' "$first" "$second"
        """#)
        let result = try fixture.install()
        try expect(result.output.utf8.count <= 262300, "retained output stays bounded while draining whole child")
        try expect(!result.output.contains("fixture-image-key") && !result.output.contains("fixture-gemini-key"), "output beyond display bound cannot leak keys")
    }

    static func packageVersions() throws {
        let fixture = try PackageFixture(script: "IFS= read -r first\nIFS= read -r second\nprintf 'Verification: OK\\n'\n")
        try fixture.saveManifest(version: "0.4.1")
        // Even a delayed launcher must deliver both keys before this success fixture exits.
        _ = try fixture.install(expectedVersion: "0.4.1", status: { _ in usleep(10000) })
        _ = try fixture.install(expectedVersion: nil)
        try expectThrows("bundle/package version mismatch is refused") { _ = try fixture.install(expectedVersion: "0.4.0") }
        for version in ["v0.4.1", "0.4", "0.04.1", "0.4.1-beta", "0.4.1\n", "9999999999.4.1"] {
            try fixture.saveManifest(version: version)
            try expectThrows("malformed or non-stable package version refused") { _ = try fixture.install(expectedVersion: nil) }
        }
    }

    static func waitsForTransaction() throws {
        let fixture = try PackageFixture(script: #"""
        exec 0<&-
        printf closed > "$HOME/input-closed"
        /bin/sleep 0.15
        printf complete > "$HOME/completed"
        printf 'Verification: OK\n'
        """#)
        var inputClosed = false
        try expectThrows("closed stdin write fails despite exit zero/verification") {
            _ = try fixture.install(status: { _ in
                guard !inputClosed else { return }
                let deadline = Date().addingTimeInterval(1)
                while !FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("input-closed").path) && Date() < deadline { usleep(1000) }
                inputClosed = FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("input-closed").path)
            })
        }
        try expect(inputClosed, "fixture closed stdin before launcher write")
        try expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("completed").path), "installer waits for commit/rollback even when child closes stdin")
    }
}
