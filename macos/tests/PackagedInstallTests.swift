import Foundation

@main struct PackagedInstallTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("resources and isolated home arguments required") }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".codex/config.toml")
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelatedProviderConfig = """
        # OPENAI_IMAGE_API_KEY is documented for another provider below.

        [mcp_servers.other.env]
        OPENAI_IMAGE_API_KEY = "unrelated-image-provider-key"
        GEMINI_IMAGE_API_KEY = "unrelated-gemini-provider-key"
        """
        try Data(unrelatedProviderConfig.utf8).write(to: config)
        let infoData = try Data(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as! [String: Any]
        let expectedVersion = info["CFBundleShortVersionString"] as! String
        let installer = OfflineInstaller(resourcesURL: resources, homeURL: home, expectedVersion: expectedVersion)
        let first = LauncherCredentials(image2Key: "packaged-image2-fixture-first", geminiKey: "packaged-gemini-fixture-first")
        let firstResult = try installer.install(credentials: first, status: { print($0) })
        precondition(firstResult.output.contains("Verification: OK"))
        precondition(!firstResult.output.contains(first.image2Key) && !firstResult.output.contains(first.geminiKey))
        let installRoot = home.appendingPathComponent(".local/share/image2-mcp")
        let env = installRoot.appendingPathComponent(".env.local")
        var contents = try String(contentsOf: env, encoding: .utf8)
        precondition(contents.contains(first.image2Key) && contents.contains(first.geminiKey))
        let configText = try String(contentsOf: config, encoding: .utf8)
        precondition(configText.contains("[mcp_servers.image2]") && !configText.contains(first.image2Key) && !configText.contains(first.geminiKey))
        precondition(configText.contains("OPENAI_IMAGE_API_KEY = \"unrelated-image-provider-key\"") &&
                     configText.contains("GEMINI_IMAGE_API_KEY = \"unrelated-gemini-provider-key\""),
                     "other MCP provider credentials are preserved")
        let second = LauncherCredentials(image2Key: "packaged-image2-fixture-second", geminiKey: "packaged-gemini-fixture-second")
        let secondResult = try installer.install(credentials: second, status: { print($0) })
        precondition(secondResult.output.contains("Verification: OK") && secondResult.output.contains("Previous installation retained at:"))
        contents = try String(contentsOf: env, encoding: .utf8)
        precondition(contents.contains(second.image2Key) && contents.contains(second.geminiKey) && !contents.contains(first.image2Key) && !contents.contains(first.geminiKey))
        for (credentials, configuredKey, omittedVariable) in [
            (LauncherCredentials(image2Key: "packaged-image2-only", geminiKey: " \t"), "packaged-image2-only", "GEMINI_IMAGE_API_KEY"),
            (LauncherCredentials(image2Key: "　", geminiKey: "packaged-gemini-only"), "packaged-gemini-only", "OPENAI_IMAGE_API_KEY")
        ] {
            let result = try installer.install(credentials: credentials, status: { print($0) })
            precondition(result.output.contains("Verification: OK"))
            precondition(!result.output.contains(configuredKey))
            contents = try String(contentsOf: env, encoding: .utf8)
            precondition(contents.contains(configuredKey) && contents.contains(omittedVariable + "=''"))
            precondition(!contents.contains(first.image2Key) && !contents.contains(first.geminiKey) && !contents.contains(second.image2Key) && !contents.contains(second.geminiKey))
            if credentials.image2Key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { precondition(!contents.contains("packaged-image2-only")) }
        }
        let configBefore = try Data(contentsOf: config)
        let envBefore = try Data(contentsOf: env)
        for credentials in [LauncherCredentials(image2Key: "", geminiKey: ""), LauncherCredentials(image2Key: " \t", geminiKey: "　"), LauncherCredentials(image2Key: "invalid\nimage2", geminiKey: ""), LauncherCredentials(image2Key: "", geminiKey: "invalid\0gemini")] {
            do {
                _ = try installer.install(credentials: credentials, status: { _ in })
                fatalError("invalid or wholly empty credentials accepted")
            } catch {
                let configAfterRefusal = try Data(contentsOf: config)
                let envAfterRefusal = try Data(contentsOf: env)
                precondition(configAfterRefusal == configBefore)
                precondition(envAfterRefusal == envBefore)
            }
        }
        let tampered = home.appendingPathComponent("tampered-resources", isDirectory: true)
        try fm.copyItem(at: resources, to: tampered)
        let arch = try NativeArchitecture.current()
        let target = tampered.appendingPathComponent("packages/" + arch + "/payload/LICENSE")
        try Data("damaged fixture".utf8).write(to: target)
        do {
            _ = try OfflineInstaller(resourcesURL: tampered, homeURL: home, expectedVersion: expectedVersion).install(credentials: second, status: { _ in })
            fatalError("tampered resources accepted")
        } catch {
            precondition(!error.localizedDescription.contains(second.image2Key) && !error.localizedDescription.contains(second.geminiKey))
        }
        let configAfter = try Data(contentsOf: config)
        let envAfter = try Data(contentsOf: env)
        precondition(configAfter == configBefore)
        precondition(envAfter == envBefore)
        print("PASS: actual packaged installation, single-provider keys, four-tool handshake, repeat/key replacement, invalid-key and tamper refusal in isolated HOME")
    }
}
