import Foundation
import CryptoKit

struct LauncherUpdateInfo {
    let version: String
    let notes: String
    let assetURL: URL
    let sha256: String
    let size: Int64
    let architectures: [String]
    let available: Bool
    fileprivate let signedManifest: Data?

    init(version: String, notes: String, assetURL: URL, sha256: String, size: Int64, architectures: [String], available: Bool) {
        self.init(version: version, notes: notes, assetURL: assetURL, sha256: sha256, size: size, architectures: architectures, available: available, signedManifest: nil)
    }

    fileprivate init(version: String, notes: String, assetURL: URL, sha256: String, size: Int64, architectures: [String], available: Bool, signedManifest: Data?) {
        self.version = version; self.notes = notes; self.assetURL = assetURL
        self.sha256 = sha256; self.size = size; self.architectures = architectures
        self.available = available; self.signedManifest = signedManifest
    }
}

private enum LauncherUpdateError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct LauncherUpdateLimits {
    static let maxManifestBytes = 256 * 1024
    static let maxAssetBytes: Int64 = 256 * 1024 * 1024
    static let production = LauncherUpdateLimits(idleTimeout: 15, overallTimeout: 300)
    let idleTimeout: TimeInterval
    let overallTimeout: TimeInterval
}

// A deliberately narrow decoder rejects duplicate keys, unknown fields, nulls,
// fractional sizes, and trailing data before Foundation can normalize them.
struct LauncherSignedManifest {
    let version: String
    let publishedAt: String
    let notes: String
    let assetURL: String
    let sha256: String
    let size: Int64
    let signature: String
    let architectures: [String]

    static func decode(_ raw: Data) throws -> LauncherSignedManifest {
        guard raw.count <= LauncherUpdateLimits.maxManifestBytes else { throw LauncherUpdateError.invalid("更新清单超过大小限制。") }
        var parser = ManifestParser(bytes: Array(raw))
        return try parser.parse()
    }

    var canonicalData: Data {
        let fields = [
            "\"version\":" + Self.quote(version),
            "\"published_at\":" + Self.quote(publishedAt),
            "\"notes\":" + Self.quote(notes),
            "\"asset_url\":" + Self.quote(assetURL),
            "\"sha256\":" + Self.quote(sha256),
            "\"size\":" + String(size),
            "\"architectures\":[" + architectures.map(Self.quote).joined(separator: ",") + "]",
        ]
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    // Match encoding/json.Marshal's default HTML escaping and UTF-8 output.
    private static func quote(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5c: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x0c: output += "\\f"
            case 0x0a: output += "\\n"
            case 0x0d: output += "\\r"
            case 0x09: output += "\\t"
            case 0...0x1f, 0x26, 0x3c, 0x3e, 0x2028, 0x2029:
                output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }
}

private struct ManifestParser {
    let bytes: [UInt8]
    var offset = 0
    private let stringFields: Set<String> = ["version", "published_at", "notes", "asset_url", "sha256", "signature"]

    mutating func parse() throws -> LauncherSignedManifest {
        try consume(123)
        var strings: [String: String] = [:]
        var size: Int64?
        var architectures: [String]?
        var seen = Set<String>()
        while true {
            skipSpace()
            if peek == 125 { offset += 1; break }
            let key = try string()
            guard seen.insert(key).inserted else { throw malformed() }
            try consume(58)
            if stringFields.contains(key) { strings[key] = try string() }
            else if key == "size" { size = try integer() }
            else if key == "architectures" { architectures = try stringArray() }
            else { throw malformed() }
            skipSpace()
            if peek == 125 { offset += 1; break }
            try consume(44)
            skipSpace()
            guard peek != 125 else { throw malformed() }
        }
        skipSpace()
        guard offset == bytes.count, seen.count == 8,
              let version = strings["version"], let published = strings["published_at"],
              let notes = strings["notes"], let asset = strings["asset_url"],
              let hash = strings["sha256"], let signature = strings["signature"],
              let size = size, let arches = architectures else { throw malformed() }
        return LauncherSignedManifest(version: version, publishedAt: published, notes: notes, assetURL: asset, sha256: hash, size: size, signature: signature, architectures: arches)
    }

    private var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }
    private func malformed() -> Error { LauncherUpdateError.invalid("更新清单 JSON 无效或包含重复、未知字段。") }
    private mutating func skipSpace() { while let value = peek, [9, 10, 13, 32].contains(value) { offset += 1 } }
    private mutating func consume(_ byte: UInt8) throws { skipSpace(); guard peek == byte else { throw malformed() }; offset += 1 }

    private mutating func string() throws -> String {
        skipSpace()
        let start = offset
        try consume(34)
        while let byte = peek {
            if byte < 32 { throw malformed() }
            offset += 1
            if byte == 92 {
                guard peek != nil else { throw malformed() }
                offset += 1
            } else if byte == 34 {
                let data = Data(bytes[start..<offset])
                guard String(data: data, encoding: .utf8) != nil,
                      let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw malformed() }
                return decoded
            }
        }
        throw malformed()
    }

    private mutating func integer() throws -> Int64 {
        skipSpace()
        let start = offset
        if peek == 45 { offset += 1 }
        guard let first = peek, (48...57).contains(first) else { throw malformed() }
        offset += 1
        if first == 48, let next = peek, (48...57).contains(next) { throw malformed() }
        while let byte = peek, (48...57).contains(byte) { offset += 1 }
        guard let value = Int64(String(decoding: bytes[start..<offset], as: UTF8.self)) else { throw malformed() }
        return value
    }

    private mutating func stringArray() throws -> [String] {
        try consume(91)
        skipSpace()
        if peek == 93 { offset += 1; return [] }
        var result: [String] = []
        while true {
            result.append(try string())
            // Only two Mac architectures can be valid; reject before allocating more.
            guard result.count <= 2 else { throw malformed() }
            skipSpace()
            if peek == 93 { offset += 1; return result }
            try consume(44)
        }
    }
}

private struct LauncherSemanticVersion: Comparable {
    let components: [UInt64]
    init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw LauncherUpdateError.invalid("版本必须为 MAJOR.MINOR.PATCH。") }
        components = try parts.map { part in
            guard !part.isEmpty, !(part.count > 1 && part.first == "0"),
                  part.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(part) else {
                throw LauncherUpdateError.invalid("版本必须为 MAJOR.MINOR.PATCH。")
            }
            return number
        }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

final class LauncherUpdater {
    static let manifestURL = URL(string: "https://api.schyler.top/image2/releases/latest/launcher-macos.json")!
    private static let trustedPublicKey = Data(base64Encoded: "hoZAzBNEtj4w+AMVbYWCRKYpOybi3Y0ekgfkDBNkIVI=")!
    private let currentVersion: String
    private let publicKey: Data
    private let architecture: String
    private let fixtureProtocol: URLProtocol.Type?
    private let limits: LauncherUpdateLimits
    private let lock = NSLock()
    private var active: LauncherUpdateTransfer?

    init(currentVersion: String) {
        self.currentVersion = currentVersion
        self.publicKey = Self.trustedPublicKey
        self.fixtureProtocol = nil
        self.limits = .production
        self.architecture = Self.nativeArchitecture()
    }

    static func nativeArchitecture() -> String {
        // On Apple Silicon this reports the hardware even for a Rosetta process.
        var hasARM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &hasARM, &size, nil, 0) == 0, hasARM == 1 { return "arm64" }
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "amd64"
        #else
        return "unsupported"
        #endif
    }

    // Local test injection never changes the production endpoint or URL policy.
    internal init(currentVersion: String, fixtureProtocol: URLProtocol.Type, publicKey: Data, architecture: String, limits: LauncherUpdateLimits = .production) {
        self.currentVersion = currentVersion; self.fixtureProtocol = fixtureProtocol
        self.publicKey = publicKey; self.architecture = architecture; self.limits = limits
    }

    static func isolatedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = nil
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    static func authenticationDisposition(for method: String) -> URLSession.AuthChallengeDisposition {
        method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
    }

    func verifyManifest(_ raw: Data) throws -> LauncherUpdateInfo {
        let manifest = try LauncherSignedManifest.decode(raw)
        guard let signature = Data(base64Encoded: manifest.signature), signature.count == 64,
              signature.base64EncodedString() == manifest.signature,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: manifest.canonicalData) else { throw LauncherUpdateError.invalid("更新清单签名验证失败。") }
        let version = try LauncherSemanticVersion(manifest.version)
        let current = try LauncherSemanticVersion(currentVersion)
        guard version >= current else { throw LauncherUpdateError.invalid("拒绝较旧版本更新。") }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = timestamp.date(from: manifest.publishedAt)
        timestamp.formatOptions = [.withInternetDateTime]
        guard Self.validTimestamp(manifest.publishedAt), fractional != nil || timestamp.date(from: manifest.publishedAt) != nil else { throw LauncherUpdateError.invalid("更新时间无效。") }
        let expected = "https://api.schyler.top/image2/releases/" + manifest.version + "/SchylerAI-Image2-mcp-macOS.dmg"
        guard manifest.assetURL == expected, let assetURL = URL(string: manifest.assetURL) else { throw LauncherUpdateError.invalid("更新地址必须是可信 HTTPS 主机上的指定版本 macOS DMG。") }
        guard manifest.size > 0, manifest.size <= LauncherUpdateLimits.maxAssetBytes else { throw LauncherUpdateError.invalid("更新文件大小无效。") }
        guard manifest.sha256.utf8.count == 64, manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw LauncherUpdateError.invalid("更新 SHA256 无效。") }
        let supported: Set<String> = ["arm64", "amd64"]
        guard !manifest.architectures.isEmpty, Set(manifest.architectures).count == manifest.architectures.count,
              manifest.architectures.allSatisfy({ supported.contains($0) }), manifest.architectures.contains(architecture) else { throw LauncherUpdateError.invalid("更新不支持当前 Mac 架构。") }
        return LauncherUpdateInfo(version: manifest.version, notes: manifest.notes, assetURL: assetURL, sha256: manifest.sha256, size: manifest.size, architectures: manifest.architectures, available: version > current, signedManifest: raw)
    }

    private static func validTimestamp(_ text: String) -> Bool {
        // ISO8601DateFormatter alone accepts some non-RFC3339 forms.
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { return false }
        let parts = text.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count == 6 else { return false }
        let year = parts[0], month = parts[1], day = parts[2]
        let leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...monthDays[month - 1]).contains(day),
              (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...59).contains(parts[5]) else { return false }
        if text.last != "Z" {
            let zone = text.suffix(5).split(separator: ":").compactMap { Int($0) }
            guard zone.count == 2, (0...23).contains(zone[0]), (0...59).contains(zone[1]) else { return false }
        }
        return true
    }

    func check(completion: @escaping (Result<LauncherUpdateInfo, Error>) -> Void) {
        begin(url: Self.manifestURL, asset: nil, destination: nil) { [self] result in
            completion(result.flatMap { data, _ in Result { try self.verifyManifest(data) } })
        }
    }

    func download(info: LauncherUpdateInfo, destinationDirectory: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            guard let raw = info.signedManifest else { throw LauncherUpdateError.invalid("下载前请先验证更新清单。") }
            let verified = try verifyManifest(raw)
            guard verified.available else { throw LauncherUpdateError.invalid("当前已是最新版本。") }
            guard destinationDirectory.isFileURL else { throw LauncherUpdateError.invalid("下载目录无效。") }
            begin(url: verified.assetURL, asset: verified, destination: destinationDirectory) { result in
                completion(result.flatMap { _, url in
                    guard let url = url else { return .failure(LauncherUpdateError.invalid("未生成已验证的更新文件。")) }
                    return .success(url)
                })
            }
        } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }

    func cancel() { lock.lock(); let operation = active; lock.unlock(); operation?.cancel() }

    private func begin(url: URL, asset: LauncherUpdateInfo?, destination: URL?, completion: @escaping (Result<(Data, URL?), Error>) -> Void) {
        lock.lock()
        guard active == nil else { lock.unlock(); DispatchQueue.main.async { completion(.failure(LauncherUpdateError.invalid("更新操作正在进行。"))) }; return }
        let config = Self.isolatedConfiguration()
        config.timeoutIntervalForRequest = limits.idleTimeout
        config.timeoutIntervalForResource = limits.overallTimeout
        if let fixtureProtocol = fixtureProtocol { config.protocolClasses = [fixtureProtocol] }
        let operation = LauncherUpdateTransfer(url: url, asset: asset, destination: destination, configuration: config, limits: limits) { [self] result in
            self.lock.lock(); self.active = nil; self.lock.unlock()
            completion(result)
        }
        active = operation
        lock.unlock()
        operation.start()
    }
}

// Each transfer has one serial queue for URLSession callbacks, file writes,
// timers and cancellation. No unverified bytes are written outside a private dir.
private final class LauncherUpdateTransfer: NSObject, URLSessionDataDelegate {
    let url: URL
    let asset: LauncherUpdateInfo?
    let destination: URL?
    let configuration: URLSessionConfiguration
    let limits: LauncherUpdateLimits
    let completion: (Result<(Data, URL?), Error>) -> Void
    let queue = DispatchQueue(label: "top.schyler.image2.update-transfer")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var idleTimer: DispatchSourceTimer?
    private var overallTimer: DispatchSourceTimer?
    private var finished = false
    private var acceptedResponse = false
    private var data = Data()
    private var count: Int64 = 0
    private var digestState = SHA256()
    private var privateDirectory: URL?
    private var partialURL: URL?
    private var file: FileHandle?

    init(url: URL, asset: LauncherUpdateInfo?, destination: URL?, configuration: URLSessionConfiguration, limits: LauncherUpdateLimits, completion: @escaping (Result<(Data, URL?), Error>) -> Void) {
        self.url = url; self.asset = asset; self.destination = destination
        self.configuration = configuration; self.limits = limits; self.completion = completion
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            do {
                if let destination = destination {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    let directory = destination.appendingPathComponent(".image2-update-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    privateDirectory = directory
                    let partial = directory.appendingPathComponent("download.partial")
                    guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LauncherUpdateError.invalid("无法创建私有更新文件。") }
                    partialURL = partial
                    file = try FileHandle(forWritingTo: partial)
                }
                let delegates = OperationQueue()
                delegates.maxConcurrentOperationCount = 1
                delegates.underlyingQueue = queue
                session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: limits.idleTimeout)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                task = session?.dataTask(with: request)
                resetIdleTimer()
                overallTimer = timer(after: limits.overallTimeout, message: "更新操作超过总时间限制。")
                task?.resume()
            } catch { finish(.failure(error)) }
        }
    }

    func cancel() { queue.async { self.finish(.failure(URLError(.cancelled))) } }

    private func timer(after interval: TimeInterval, message: String) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in self?.finish(.failure(LauncherUpdateError.invalid(message))) }
        timer.resume()
        return timer
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        idleTimer = timer(after: limits.idleTimeout, message: "更新连接长时间未收到数据。")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, response.url == url, response.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(LauncherUpdateError.invalid("更新服务器未返回成功响应；不允许重定向。"))); return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else { completionHandler(.cancel); finish(.failure(LauncherUpdateError.invalid("更新响应不允许内容编码。"))); return }
        let maximum = asset?.size ?? Int64(LauncherUpdateLimits.maxManifestBytes)
        if let rawLength = response.value(forHTTPHeaderField: "Content-Length") {
            guard let length = Int64(rawLength), length >= 0, length <= maximum, asset == nil || length == maximum else {
                completionHandler(.cancel); finish(.failure(LauncherUpdateError.invalid("更新响应大小与清单不符或超过限制。"))); return
            }
        }
        acceptedResponse = true
        resetIdleTimer()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished, acceptedResponse else { return }
        let maximum = asset?.size ?? Int64(LauncherUpdateLimits.maxManifestBytes)
        guard Int64(chunk.count) <= maximum - count else { finish(.failure(LauncherUpdateError.invalid("更新响应超过大小限制。"))); return }
        do {
            if let file = file { try file.write(contentsOf: chunk); digestState.update(data: chunk) }
            else { data.append(chunk) }
            count += Int64(chunk.count)
            resetIdleTimer()
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error = error { finish(.failure(error)); return }
        guard acceptedResponse else { finish(.failure(LauncherUpdateError.invalid("更新响应缺失。"))); return }
        do {
            if let asset = asset {
                guard count == asset.size else { throw LauncherUpdateError.invalid("下载文件大小与清单不符。") }
                let digest = digestState.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == asset.sha256 else { throw LauncherUpdateError.invalid("下载文件 SHA256 验证失败。") }
                try file?.synchronize()
                try file?.close(); file = nil
                guard let partial = partialURL, let directory = privateDirectory else { throw LauncherUpdateError.invalid("更新临时文件缺失。") }
                let final = directory.appendingPathComponent("SchylerAI-Image2-mcp-macOS.dmg")
                try FileManager.default.moveItem(at: partial, to: final)
                finish(.success((Data(), final)))
            } else { finish(.success((data, nil))) }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(LauncherUpdateError.invalid("更新请求不允许重定向。")))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(LauncherUpdater.authenticationDisposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(LauncherUpdater.authenticationDisposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    private func finish(_ result: Result<(Data, URL?), Error>) {
        guard !finished else { return }
        finished = true
        idleTimer?.cancel(); idleTimer = nil
        overallTimer?.cancel(); overallTimer = nil
        try? file?.close(); file = nil
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        if case .failure = result, let directory = privateDirectory { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.main.async { self.completion(result) }
    }
}
