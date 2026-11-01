import Foundation
import CryptoKit
import Darwin

struct LauncherCredentials {
    let image2Key: String
    let geminiKey: String

    init(image2Key: String, geminiKey: String) {
        self.image2Key = Self.optionalKey(image2Key)
        self.geminiKey = Self.optionalKey(geminiKey)
    }

    func validate() throws {
        for (provider, value) in [("Image2", image2Key), ("Gemini", geminiKey)] {
            guard Self.wellFormedKey(value) else {
                throw validationError("\(provider) API Key 必须为单行，且不超过 1024 字节。")
            }
        }
        guard !image2Key.isEmpty || !geminiKey.isEmpty else {
            throw validationError("请至少填写一项 API Key。")
        }
    }

    var stdinData: Data { Data((image2Key + "\n" + geminiKey + "\n").utf8) }

    private static func optionalKey(_ value: String) -> String {
        // Malformed input must survive normalization so validation can refuse it.
        wellFormedKey(value) && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : value
    }

    private static func wellFormedKey(_ value: String) -> Bool {
        value.utf8.count <= 1024 && !value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 })
    }

    private func validationError(_ text: String) -> LauncherCoreError {
        LauncherCoreError(InstallerOutputCapture.redacted(text, secrets: [image2Key, geminiKey]), diagnostic: .credentials)
    }
}

enum LauncherInstallDiagnostic {
    case credentials, resources, home, configuration, existingInstallation
    case permission, architecture, process, input, verification, unknown

    var code: String {
        switch self {
        case .credentials: "INSTALL_CREDENTIALS"
        case .resources: "INSTALL_RESOURCES"
        case .home: "INSTALL_HOME"
        case .configuration: "INSTALL_CONFIGURATION"
        case .existingInstallation: "INSTALL_EXISTING_TARGET"
        case .permission: "INSTALL_PERMISSION"
        case .architecture: "INSTALL_ARCHITECTURE"
        case .process: "INSTALL_PROCESS"
        case .input: "INSTALL_INPUT"
        case .verification: "INSTALL_VERIFICATION"
        case .unknown: "INSTALL_UNKNOWN"
        }
    }

    var summary: String {
        switch self {
        case .credentials: "密钥输入不符合要求。"
        case .resources: "应用内的离线安装资源缺失、损坏或版本不匹配。"
        case .home: "无法定位或访问当前用户的安装目录。"
        case .configuration: "Codex 配置文件无法读取、更新或验证。"
        case .existingInstallation: "现有安装目录不完整或无法安全更新。"
        case .permission: "当前用户没有完成安装所需的文件权限。"
        case .architecture: "无法识别当前 Mac 架构或选择对应的离线安装程序。"
        case .process: "本机安装程序未能正常完成。"
        case .input: "无法安全地向安装程序传递配置。"
        case .verification: "安装后的本地连接验证未通过。"
        case .unknown: "安装程序未能完成本机安装。"
        }
    }

    var recovery: String {
        switch self {
        case .credentials: "请确认至少填写一项有效密钥，然后重试。"
        case .resources: "请重新下载完整应用，并从应用程序目录打开后重试。"
        case .home: "请确认当前 macOS 用户目录可用，然后重试。"
        case .configuration: "请检查 ~/.codex/config.toml 是否可写、格式是否受支持，然后重试。"
        case .existingInstallation: "请检查安装目录及其中的 .image2-mcp-managed 标记，然后重试。"
        case .permission: "请确认当前用户可以写入自身主目录，再重试。"
        case .architecture: "请确认此 Mac 使用受支持的 Apple 芯片或 Intel 架构，并重新获取应用。"
        case .process: "请重新打开完整的 SchylerAI-Image2-mcp.app 后重试。"
        case .input: "请重新打开应用、重新输入要使用的密钥后重试。"
        case .verification: "请检查配置文件和安装目录；修复后重新输入密钥并重试。"
        case .unknown: "请从应用程序目录重新打开完整应用；若仍失败，请反馈此诊断代码。"
        }
    }
}

struct LauncherCoreError: Error, LocalizedError {
    let message: String
    let diagnostic: LauncherInstallDiagnostic?
    let exitStatus: Int32?

    init(_ message: String, diagnostic: LauncherInstallDiagnostic? = nil, exitStatus: Int32? = nil) {
        self.message = message
        self.diagnostic = diagnostic
        self.exitStatus = exitStatus
    }
    var errorDescription: String? { message }
}

struct LauncherInstallationResult { let output: String }

struct OfflineInstaller {
    let resourcesURL: URL
    let homeURL: URL
    let expectedVersion: String?

    // Credential-free release check: exercise the same optimized staging and
    // cleanup code used by the GUI without changing any user configuration.
    static func verifyResources(at resourcesURL: URL, expectedVersion: String) throws {
        let package = try PrivatePackage(resourcesURL: resourcesURL,
                                         architecture: NativeArchitecture.current(),
                                         expectedVersion: expectedVersion)
        package.remove()
    }

    init(resourcesURL: URL, homeURL: URL, expectedVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.resourcesURL = resourcesURL
        self.homeURL = homeURL
        self.expectedVersion = expectedVersion
    }

    func install(credentials: LauncherCredentials, status: @escaping (String) -> Void) throws -> LauncherInstallationResult {
        let secrets = [credentials.image2Key, credentials.geminiKey]
        do {
            return try performInstall(credentials: credentials, status: { status(InstallerOutputCapture.redacted($0, secrets: secrets)) })
        } catch let error as LauncherCoreError {
            throw LauncherCoreError(InstallerOutputCapture.redacted(error.localizedDescription, secrets: secrets),
                                    diagnostic: error.diagnostic ?? .unknown, exitStatus: error.exitStatus)
        } catch {
            throw LauncherCoreError(InstallerOutputCapture.redacted(error.localizedDescription, secrets: secrets), diagnostic: .unknown)
        }
    }

    private func performInstall(credentials: LauncherCredentials, status: @escaping (String) -> Void) throws -> LauncherInstallationResult {
        try credentials.validate()
        guard homeURL.isFileURL, homeURL.path.hasPrefix("/") else { throw LauncherCoreError("安装主目录无效。", diagnostic: .home) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: homeURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LauncherCoreError("安装主目录不可用。", diagnostic: .home)
        }
        status("正在校验离线安装资源……")
        let architecture: String
        do { architecture = try NativeArchitecture.current() }
        catch { throw LauncherCoreError("无法识别 Mac 架构。", diagnostic: .architecture) }
        let staging: PrivatePackage
        do { staging = try PrivatePackage(resourcesURL: resourcesURL, architecture: architecture, expectedVersion: expectedVersion) }
        catch { throw LauncherCoreError("离线安装资源缺失、已损坏或版本不匹配。", diagnostic: .resources) }
        defer { staging.remove() }
        let child = Process()
        let command = NativeArchitecture.installerCommand(packageArchitecture: architecture, processArchitecture: try NativeArchitecture.processMachine())
        child.executableURL = URL(fileURLWithPath: command[0])
        child.arguments = Array(command.dropFirst())
        child.currentDirectoryURL = staging.packageURL
        child.environment = ["HOME": homeURL.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                             "TMPDIR": staging.temporaryURL.path + "/", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        // Avoid process-wide SIGPIPE handling: a closed child stdin must only fail this write.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw LauncherCoreError("无法创建安全的安装输入通道。", diagnostic: .input)
        }
        do { try child.run() } catch { throw LauncherCoreError("无法启动离线安装程序。", diagnostic: .process) }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let capture = InstallerOutputCapture(secrets: [credentials.image2Key, credentials.geminiKey])
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? output.fileHandleForReading.close(); drained.leave() }
            while true {
                do {
                    guard let data = try output.fileHandleForReading.read(upToCount: 16384), !data.isEmpty else { break }
                    capture.consume(data)
                } catch { capture.readFailed = true; break }
            }
            capture.finish()
        }
        status("正在安装；请等待安装或回滚完成……")
        var inputFailed = false
        do { try input.fileHandleForWriting.write(contentsOf: credentials.stdinData) } catch { inputFailed = true }
        try? input.fileHandleForWriting.close()
        // Once launched, never terminate this transaction, including when stdin fails.
        child.waitUntilExit()
        drained.wait()
        let safeOutput = capture.output
        guard !inputFailed, !capture.readFailed, child.terminationReason == .exit, child.terminationStatus == 0, capture.verified else {
            let detail = safeOutput.isEmpty ? "" : "\n" + safeOutput
            let diagnostic = Self.diagnostic(for: safeOutput)
            throw LauncherCoreError("安装未通过验证；安装程序已退出，请查看结果后重试。" + detail,
                                    diagnostic: inputFailed ? .input : diagnostic,
                                    exitStatus: child.terminationReason == .exit ? child.terminationStatus : nil)
        }
        status("安装完成，请重启 Codex 或打开新对话。")
        return LauncherInstallationResult(output: safeOutput)
    }

    private static func diagnostic(for output: String) -> LauncherInstallDiagnostic {
        let lower = output.lowercased()
        if lower.contains("at least one image2 or gemini api key") { return .credentials }
        if lower.contains("unsupported image2 toml") || lower.contains("unsupported conflicting image2 toml") ||
            lower.contains("codex config") { return .configuration }
        if lower.contains("existing archive target") || lower.contains("managed target") ||
            lower.contains("existing target") { return .existingInstallation }
        if lower.contains("permission denied") || lower.contains("operation not permitted") { return .permission }
        if lower.contains("unsupported architecture") || lower.contains("offline binary version/platform check failed") { return .architecture }
        if lower.contains("missing regular bundled binary") || lower.contains("offline package") ||
            lower.contains("sha-256 mismatch") || lower.contains("manifest") || lower.contains("payload") { return .resources }
        if lower.contains("mcp verification") || lower.contains("mcp handshake") || lower.contains("environment verification") ||
            lower.contains("binary verification") || lower.contains("runner verification") { return .verification }
        return .process
    }
}

// Convert mkdtemp's borrowed pointer to an owned String inside its lifetime.
// Cleanup accepts only this instance's unchanged, owned temporary directory.
struct LauncherPrivateDirectory {
    let url: URL
    private let parentURL: URL
    private let device: dev_t
    private let inode: ino_t

    init(parentURL: URL = FileManager.default.temporaryDirectory) throws {
        let parent = parentURL.resolvingSymlinksInPath().standardizedFileURL
        guard parent.isFileURL, parent.path.hasPrefix("/"), parent.path != "/" else {
            throw Self.invalid()
        }
        var template = Array(parent.appendingPathComponent("image2-launcher.XXXXXX").path.utf8CString)
        let createdPath: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let created = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: created)
        }
        guard let createdPath = createdPath else { throw Self.invalid() }
        let root = try Self.validatedURL(createdPath: createdPath, parentURL: parent)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Self.invalid() }
        self.url = root
        self.parentURL = parent
        self.device = info.st_dev
        self.inode = info.st_ino
    }

    static func validatedURL(createdPath: String, parentURL: URL) throws -> URL {
        // Reject raw empty/relative paths before URL resolves them against cwd.
        guard createdPath.hasPrefix("/"), !createdPath.utf8.contains(0) else { throw invalid() }
        let candidate = URL(fileURLWithPath: createdPath, isDirectory: true)
        let name = candidate.lastPathComponent
        let prefix = "image2-launcher."
        guard candidate.deletingLastPathComponent() == parentURL,
              createdPath == parentURL.path + "/" + name,
              name.hasPrefix(prefix), name.utf8.count == prefix.utf8.count + 6,
              name.dropFirst(prefix.count).utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              }) else { throw invalid() }
        return candidate
    }

    func remove() {
        guard (try? Self.validatedURL(createdPath: url.path, parentURL: parentURL)) == url else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_dev == device, info.st_ino == inode else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func invalid() -> LauncherCoreError {
        LauncherCoreError("无法创建或确认安全的安装暂存目录。", diagnostic: .resources)
    }
}

private struct ResourceManifest: Decodable {
    let version: String
    let files: [Entry]
    struct Entry: Decodable { let path: String; let sha256: String; let size: Int }
}

private final class PrivatePackage {
    static let maximumManifestBytes = 256 * 1024
    static let maximumFileBytes = 256 * 1024 * 1024
    static let maximumPackageBytes = 256 * 1024 * 1024
    static let maximumEntries = 512
    private let privateDirectory: LauncherPrivateDirectory
    let rootURL: URL
    let packageURL: URL
    let temporaryURL: URL

    init(resourcesURL: URL, architecture: String, expectedVersion: String?) throws {
        guard resourcesURL.isFileURL, resourcesURL.path.hasPrefix("/") else { throw Self.invalid() }
        let source = open(resourcesURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw Self.invalid() }
        defer { close(source) }
        let manifestData = try Self.readFile(root: source, path: "resource-manifest.json", maximumBytes: Self.maximumManifestBytes)
        let manifest: ResourceManifest
        do { manifest = try JSONDecoder().decode(ResourceManifest.self, from: manifestData) } catch { throw Self.invalid() }
        guard Self.validVersion(manifest.version), expectedVersion == nil || expectedVersion == manifest.version,
              !manifest.files.isEmpty, manifest.files.count <= Self.maximumEntries else { throw Self.invalid() }
        var paths = Set<String>()
        for entry in manifest.files {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard entry.path.utf8.count <= 512, components.count >= 3, components[0] == "packages",
                  ["arm64", "amd64"].contains(String(components[1])),
                  components.allSatisfy({ component in
                      !component.isEmpty && component != "." && component != ".." && component.utf8.allSatisfy {
                          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
                      }
                  }),
                  paths.insert(entry.path.lowercased()).inserted, entry.size >= 0, entry.size <= Self.maximumFileBytes,
                  entry.sha256.utf8.count == 64, entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Self.invalid() }
        }
        let prefix = "packages/" + architecture + "/"
        let selected = manifest.files.filter { $0.path.hasPrefix(prefix) }
        guard !selected.isEmpty, selected.contains(where: { $0.path == prefix + "install-offline.sh" }),
              selected.reduce(0, { $0 + $1.size }) <= Self.maximumPackageBytes else { throw Self.invalid() }
        try Self.validateTree(root: source, prefix: prefix, expectedPaths: Set(selected.map { $0.path }))
        privateDirectory = try LauncherPrivateDirectory()
        rootURL = privateDirectory.url
        packageURL = rootURL.appendingPathComponent("package", isDirectory: true)
        temporaryURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for entry in selected {
                let destination = packageURL.appendingPathComponent(String(entry.path.dropFirst(prefix.count)))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Self.copyVerified(root: source, entry: entry, destination: destination)
            }
        } catch { privateDirectory.remove(); throw Self.invalid() }
    }

    func remove() { privateDirectory.remove() }
    private static func invalid() -> LauncherCoreError { LauncherCoreError("离线安装资源缺失、已损坏或不安全；请重新下载完整应用。") }

    private static func validVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.count <= 9 && (part.count == 1 || part.first != "0") && part.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private static func validateTree(root: Int32, prefix: String, expectedPaths: Set<String>) throws {
        var package = dup(root)
        guard package >= 0 else { throw invalid() }
        for component in prefix.split(separator: "/") {
            let next = openat(package, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(package)
            guard next >= 0 else { throw invalid() }
            package = next
        }
        defer { close(package) }
        var actual = Set<String>()
        var count = 0
        func visit(_ directory: Int32, relative: String) throws {
            let duplicate = dup(directory)
            guard duplicate >= 0 else { throw invalid() }
            guard let stream = fdopendir(duplicate) else { close(duplicate); throw invalid() }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw invalid() }
                    break
                }
                let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                count += 1
                let path = relative + name
                guard count <= 4096, path.utf8.count <= 512 else { throw invalid() }
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw invalid() }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw invalid() }
                    defer { close(child) }
                    try visit(child, relative: path + "/")
                case S_IFREG:
                    guard info.st_nlink == 1 else { throw invalid() }
                    actual.insert(prefix + path)
                default: throw invalid()
                }
            }
        }
        try visit(package, relative: "")
        guard actual == expectedPaths else { throw invalid() }
    }

    private static func openRegular(root: Int32, path: String) throws -> (Int32, stat) {
        var directory = dup(root)
        guard directory >= 0 else { throw invalid() }
        defer { close(directory) }
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw invalid() }
            close(directory)
            directory = next
        }
        let file = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw invalid() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { close(file); throw invalid() }
        return (file, info)
    }

    private static func readFile(root: Int32, path: String, maximumBytes: Int) throws -> Data {
        let (descriptor, info) = try openRegular(root: root, path: path)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw invalid() }
        guard let data = try? file.read(upToCount: maximumBytes + 1), data.count <= maximumBytes, data.count == info.st_size else { throw invalid() }
        return data
    }

    private static func copyVerified(root: Int32, entry: ResourceManifest.Entry, destination: URL) throws {
        let (descriptor, info) = try openRegular(root: root, path: entry.path)
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? source.close() }
        guard info.st_size == entry.size else { throw invalid() }
        let targetDescriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600 | (info.st_mode & 0o111)))
        guard targetDescriptor >= 0 else { throw invalid() }
        let target = FileHandle(fileDescriptor: targetDescriptor, closeOnDealloc: true)
        defer { try? target.close() }
        var digest = SHA256()
        var total = 0
        while let data = try source.read(upToCount: 65536), !data.isEmpty {
            total += data.count
            guard total <= entry.size else { throw invalid() }
            digest.update(data: data)
            try target.write(contentsOf: data)
        }
        let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == entry.size, actualHash == entry.sha256 else { throw invalid() }
    }
}

// Only the drain worker mutates this object; the caller reads it after DispatchGroup.wait.
private final class InstallerOutputCapture: @unchecked Sendable {
    private let secrets: [[UInt8]]
    private let maximumSecretLength: Int
    private let replacement: [UInt8]
    private let secretStrings: [String]
    private var pending: [UInt8] = []
    private var masked: [Bool] = []
    private var redacting = false
    private var retained = Data()
    private var truncated = false
    private var line: [UInt8] = []
    private var lineOverflow = false
    private(set) var verified = false
    var readFailed = false

    init(secrets: [String]) {
        secretStrings = secrets.filter { $0.utf8.count <= 1024 }
        self.secrets = secretStrings.map { Array($0.utf8) }.filter { !$0.isEmpty }
        maximumSecretLength = self.secrets.map(\.count).max() ?? 1
        let usedScalars = Set(secretStrings.joined().unicodeScalars.map(\.value))
        let scalar = ([UInt32(0x2588)] + Array(UInt32(0xE000)...UInt32(0xF8FF))).first { !usedScalars.contains($0) }!
        replacement = Array(String(UnicodeScalar(scalar)!).utf8)
    }

    func consume(_ data: Data) {
        for byte in data {
            if byte == 10 { finishLine() }
            else if line.count < 64 { line.append(byte) }
            else { lineOverflow = true }
        }
        pending.append(contentsOf: data)
        masked.append(contentsOf: repeatElement(false, count: data.count))
        redact(final: false)
    }

    func finish() { finishLine(); redact(final: true) }

    var output: String {
        Self.redacted(String(decoding: retained, as: UTF8.self), secrets: secretStrings) + (truncated ? Self.redacted("\n[安装输出已截断]\n", secrets: secretStrings) : "")
    }

    static func redacted(_ text: String, secrets: [String]) -> String {
        let capture = InstallerOutputCapture(secrets: secrets)
        capture.consume(Data(text.utf8))
        capture.finish()
        // String input is valid UTF-8; only the bounded final prefix can cut a scalar.
        var prefix = capture.retained
        for _ in 0..<4 {
            if let valid = String(data: prefix, encoding: .utf8) { return valid }
            if !prefix.isEmpty { prefix.removeLast() }
        }
        return ""
    }

    private func finishLine() {
        if !lineOverflow && (line == Array("Verification: OK".utf8) || line == Array("Verification: OK\r".utf8)) { verified = true }
        line.removeAll(keepingCapacity: true)
        lineOverflow = false
    }

    private func redact(final: Bool) {
        var processed = 0
        while processed < pending.count && (final || pending.count - processed >= maximumSecretLength) {
            // Mark every occurrence, so overlapping provider values produce one redacted span.
            for secret in secrets where secret.count <= pending.count - processed {
                if pending[processed..<(processed + secret.count)].elementsEqual(secret) {
                    for index in processed..<(processed + secret.count) { masked[index] = true }
                }
            }
            if masked[processed] {
                if !redacting { append(replacement); redacting = true }
            } else { append([pending[processed]]); redacting = false }
            processed += 1
        }
        pending.removeFirst(processed)
        masked.removeFirst(processed)
    }

    private func append(_ bytes: [UInt8]) {
        let available = 256 * 1024 - retained.count
        retained.append(contentsOf: bytes.prefix(available))
        if bytes.count > available { truncated = true }
    }
}

enum NativeArchitecture {
    static func current() throws -> String {
        let machine = try processMachine()
        var arm64: Int32 = 0
        var size = MemoryLayout.size(ofValue: arm64)
        let arm64Hardware = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
        return try resolve(machine: machine, arm64Hardware: arm64Hardware)
    }

    static func processMachine() throws -> String {
        var hardware = utsname()
        guard uname(&hardware) == 0 else { throw LauncherCoreError("无法识别 Mac 硬件架构。") }
        let machineCapacity = MemoryLayout.size(ofValue: hardware.machine)
        let machine = withUnsafePointer(to: &hardware.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineCapacity) { String(cString: $0) }
        }
        return machine
    }

    static func resolve(machine: String, arm64Hardware: Bool) throws -> String {
        if machine == "arm64" || (machine == "x86_64" && arm64Hardware) { return "arm64" }
        if machine == "x86_64" { return "amd64" }
        throw LauncherCoreError("此 Mac 的硬件架构不受支持。")
    }

    static func installerCommand(packageArchitecture: String, processArchitecture: String) -> [String] {
        if packageArchitecture == "arm64" && processArchitecture == "x86_64" {
            return ["/usr/bin/arch", "-arm64", "/bin/bash", "install-offline.sh"]
        }
        return ["/bin/bash", "install-offline.sh"]
    }
}
