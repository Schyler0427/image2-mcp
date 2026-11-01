import Foundation
import CryptoKit

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let value) = self { return value }; return "test failure" }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.failed(message) }
}

private func expectFailure(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch is TestFailure { throw TestFailure.failed("assertion failed in \(label)") } catch { return }
    throw TestFailure.failed("accepted \(label)")
}

private let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
private let localPrivateKey = Curve25519.Signing.PrivateKey()
private let fixtureAsset = Data("local fixture dmg\n".utf8)
private let fixtureURL = URL(string: "https://api.schyler.top/image2/releases/1.2.3/SchylerAI-Image2-mcp-macOS.dmg")!

private func fixtureDictionary() throws -> [String: Any] {
    let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent("go-update-manifest.json"))
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func manifest(_ changes: [String: Any] = [:]) throws -> Data {
    var fields = try fixtureDictionary()
    for (key, value) in changes { fields[key] = value }
    fields["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
    let unsigned = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    let payload = try LauncherSignedManifest.decode(unsigned).canonicalData
    fields["signature"] = try localPrivateKey.signature(for: payload).base64EncodedString()
    return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
}

private struct FixtureResponse {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var redirect: URL?
    var stalls = false
    var delay: TimeInterval = 0
    var authenticationChallenge = false
    var stallsAfterChunks = false
}

private final class FixtureURLProtocol: URLProtocol, URLAuthenticationChallengeSender {
    static let lock = NSLock()
    static var responder: ((URLRequest) throws -> FixtureResponse)?
    static var requests: [URLRequest] = []
    private var stopped = false
    private let stateLock = NSLock()

    static func reset(_ block: @escaping (URLRequest) throws -> FixtureResponse) {
        lock.lock(); defer { lock.unlock() }
        responder = block; requests = []
    }
    static var capturedRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let handler = Self.responder; Self.lock.unlock()
        do {
            guard let handler = handler else { throw TestFailure.failed("unexpected request") }
            let scripted = try handler(request)
            if scripted.stalls { return }
            if scripted.authenticationChallenge {
                let protection = URLProtectionSpace(host: request.url!.host!, port: 443, protocol: "https", realm: "local fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
                let challenge = URLAuthenticationChallenge(protectionSpace: protection, proposedCredential: URLCredential(user: "forbidden", password: "forbidden", persistence: .none), previousFailureCount: 0, failureResponse: nil, error: nil, sender: self)
                client?.urlProtocol(self, didReceive: challenge)
                return
            }
            let emit = { [self] in
                self.stateLock.lock(); let cancelled = self.stopped; self.stateLock.unlock()
                if cancelled { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: scripted.status, httpVersion: "HTTP/1.1", headerFields: scripted.headers)!
                if let target = scripted.redirect {
                    self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                    return
                }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in scripted.chunks { self.client?.urlProtocol(self, didLoad: chunk) }
                if scripted.stallsAfterChunks { return }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if scripted.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + scripted.delay, execute: emit) } else { emit() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(self, didFailWithError: TestFailure.failed("updater supplied an authentication credential"))
    }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
    }
    func cancel(_ challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(self, didFailWithError: URLError(.userCancelledAuthentication))
    }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(self, didFailWithError: TestFailure.failed("updater used default HTTP authentication handling"))
    }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
    }
}

private func updater(current: String = "1.2.2", architecture: String = "arm64", limits: LauncherUpdateLimits = .production) -> LauncherUpdater {
    LauncherUpdater(currentVersion: current, fixtureProtocol: FixtureURLProtocol.self, publicKey: localPrivateKey.publicKey.rawRepresentation, architecture: architecture, limits: limits)
}

private func awaitResult<T>(_ action: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> Result<T, Error> {
    var result: Result<T, Error>?
    action { value in
        if !Thread.isMainThread { result = .failure(TestFailure.failed("completion was not on main thread")) } else { result = value }
    }
    let deadline = Date().addingTimeInterval(4)
    while result == nil && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    guard let value = result else { throw TestFailure.failed("timed out waiting for completion") }
    return value
}

private func temporaryDirectory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-update-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return path
}

@main
struct LauncherUpdateTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("Go canonical escaping and signature golden", testGoGolden),
            ("equivalent JSON string escaping", testEquivalentEscaping),
            ("strict JSON schema and syntax", testStrictJSON),
            ("signature and signing key rejection", testSignature),
            ("semantic version comparisons", testVersions),
            ("fixed host and exact Mac DMG path", testAssetURL),
            ("Mac architectures and bounds", testMetadata),
            ("fixed endpoint and isolated request state", testCheck),
            ("HTTP authentication refusal", testAuthentication),
            ("manifest transport bounds and errors", testManifestTransport),
            ("streamed verified private DMG", testDownload),
            ("digest size and redirect refusal", testDownloadFailures),
            ("cancellation and timeout cleanup", testCancellationAndTimeouts),
        ]
        var failures = 0
        for (name, body) in tests {
            do { try body(); print("PASS: \(name)") } catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) updater test groups passed")
        if failures != 0 { exit(1) }
    }

    static func testGoGolden() throws {
        let raw = try Data(contentsOf: fixtureDirectory.appendingPathComponent("go-update-manifest.json"))
        let expected = try Data(contentsOf: fixtureDirectory.appendingPathComponent("go-update-canonical.json"))
        let keyText = try String(contentsOf: fixtureDirectory.appendingPathComponent("go-update-public-key.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = try LauncherSignedManifest.decode(raw)
        try expect(decoded.canonicalData == expected, "Swift canonical bytes differ from Go json.Marshal golden")
        let client = LauncherUpdater(currentVersion: "1.2.2", fixtureProtocol: FixtureURLProtocol.self, publicKey: Data(base64Encoded: keyText)!, architecture: "arm64")
        let info = try client.verifyManifest(raw)
        try expect(info.version == "1.2.3" && info.available && info.assetURL == fixtureURL, "golden did not verify")
        try expect(info.notes.contains("中文") && info.notes.contains("😀"), "Unicode notes changed")
    }

    static func testStrictJSON() throws {
        let valid = try manifest()
        let text = String(decoding: valid, as: UTF8.self)
        let invalid: [String] = [
            "{}", "[]", text + " {}", text + " garbage",
            text.replacingOccurrences(of: "{", with: "{\"unknown\":1,", options: [], range: text.startIndex..<text.index(after: text.startIndex)),
            text.replacingOccurrences(of: "{", with: "{\"version\":\"9.9.9\",", options: [], range: text.startIndex..<text.index(after: text.startIndex)),
            text.replacingOccurrences(of: "{", with: "{\"\\u0076ersion\":\"9.9.9\",", options: [], range: text.startIndex..<text.index(after: text.startIndex)),
            text.replacingOccurrences(of: "\"size\":18", with: "\"size\":1.8e1"),
            text.replacingOccurrences(of: "\"size\":18", with: "\"size\":18.0"),
            text.replacingOccurrences(of: "\"size\":18", with: "\"size\":true"),
            text.replacingOccurrences(of: "\"size\":18", with: "\"size\":018"),
            text.replacingOccurrences(of: "\"size\":18", with: "\"size\":9223372036854775808"),
            text.replacingOccurrences(of: "\"notes\":", with: "\"notes\":null,\"other\":"),
            text.replacingOccurrences(of: "\"version\":\"1.2.3\"", with: "\"version\":\"\\ud800\""),
        ]
        for (index, value) in invalid.enumerated() { try expectFailure("invalid JSON case \(index)") { _ = try updater().verifyManifest(Data(value.utf8)) } }
        var badUTF8 = valid; badUTF8.insert(0xff, at: 1)
        try expectFailure("invalid UTF8") { _ = try updater().verifyManifest(badUTF8) }
        try expectFailure("oversized manifest") { _ = try updater().verifyManifest(Data(repeating: 32, count: 256 * 1024 + 1)) }
        _ = try updater().verifyManifest(valid + Data(" \n\t".utf8))
    }

    static func testEquivalentEscaping() throws {
        let raw = try manifest()
        let text = String(decoding: raw, as: UTF8.self)
        let escaped = text.replacingOccurrences(of: "😀", with: "\\ud83d\\ude00").replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "中文", with: "\\u4e2d\\u6587")
        let expected = try updater().verifyManifest(raw)
        let actual = try updater().verifyManifest(Data(escaped.utf8))
        try expect(actual.notes == expected.notes && actual.assetURL == expected.assetURL, "equivalent escaping changes signed values")
    }

    static func testSignature() throws {
        let raw = try manifest()
        let tampered = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "1.2.3", with: "1.2.4").utf8)
        try expectFailure("tampered signature") { _ = try updater().verifyManifest(tampered) }
        var dict = try fixtureDictionary(); dict["signature"] = "bad"
        try expectFailure("malformed signature") { _ = try updater().verifyManifest(JSONSerialization.data(withJSONObject: dict)) }
        let other = LauncherUpdater(currentVersion: "1.2.2", fixtureProtocol: FixtureURLProtocol.self, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, architecture: "arm64")
        try expectFailure("different signing key") { _ = try other.verifyManifest(raw) }
        try expectFailure("production key mismatch") { _ = try LauncherUpdater(currentVersion: "1.2.2").verifyManifest(raw) }
        try expect(LauncherUpdater.manifestURL.absoluteString == "https://api.schyler.top/image2/releases/latest/launcher-macos.json", "wrong production endpoint")
    }

    static func testVersions() throws {
        let raw = try manifest()
        try expect(try updater(current: "1.2.3").verifyManifest(raw).available == false, "equal version marked available")
        try expect(try updater(current: "1.1.999").verifyManifest(raw).available, "numeric comparison wrong")
        try expectFailure("downgrade") { _ = try updater(current: "1.2.4").verifyManifest(raw) }
        for version in ["1.2", "v1.2.3", "01.2.3", "1.2.3-rc.1", "1.2.3+build", "-1.2.3", "1.2.3 ", "18446744073709551616.0.0"] {
            try expectFailure("current version \(version)") { _ = try updater(current: version).verifyManifest(raw) }
            try expectFailure("manifest version \(version)") { _ = try updater().verifyManifest(manifest(["version": version])) }
        }
    }

    static func testAssetURL() throws {
        let valid = fixtureURL.absoluteString
        for url in [
            valid.replacingOccurrences(of: "https:", with: "http:"),
            valid.replacingOccurrences(of: "api.schyler.top", with: "evil.example"),
            valid.replacingOccurrences(of: "api.schyler.top", with: "api.schyler.top.evil.example"),
            valid.replacingOccurrences(of: "api.schyler.top", with: "api.schyler.top:443"),
            valid.replacingOccurrences(of: "api.schyler.top", with: "user:pass@api.schyler.top"),
            valid + "?token=x", valid + "#fragment",
            valid.replacingOccurrences(of: "/1.2.3/", with: "/1.2.4/"),
            valid.replacingOccurrences(of: "/1.2.3/", with: "/latest/"),
            valid.replacingOccurrences(of: "/1.2.3/", with: "/foo/../1.2.3/"),
            valid.replacingOccurrences(of: "/1.2.3/", with: "/%31.2.3/"),
            valid.replacingOccurrences(of: "-macOS.dmg", with: ".exe"),
            valid.replacingOccurrences(of: "-macOS.dmg", with: "-macOS.zip"),
        ] { try expectFailure("asset URL \(url)") { _ = try updater().verifyManifest(manifest(["asset_url": url])) } }
    }

    static func testMetadata() throws {
        try expect(["arm64", "amd64"].contains(LauncherUpdater.nativeArchitecture()), "native hardware architecture unsupported")
        for architectures in [[], ["arm64", "arm64"], ["386"], ["x86_64"], ["mips"], ["amd64"]] as [[String]] {
            try expectFailure("architecture \(architectures)") { _ = try updater().verifyManifest(manifest(["architectures": architectures])) }
        }
        _ = try updater(architecture: "amd64").verifyManifest(manifest(["architectures": ["amd64"]]))
        for size: Int64 in [0, -1, 256 * 1024 * 1024 + 1] { try expectFailure("size \(size)") { _ = try updater().verifyManifest(manifest(["size": size])) } }
        for digest in ["", String(repeating: "a", count: 63), String(repeating: "g", count: 64)] { try expectFailure("digest \(digest)") { _ = try updater().verifyManifest(manifest(["sha256": digest])) } }
        for timestamp in ["", "yesterday", "2026-13-99T00:00:00Z", "2026-02-31T00:00:00Z", "2026-10-28T24:00:00Z", "2026-10-28T00:60:00Z"] { try expectFailure("timestamp \(timestamp)") { _ = try updater().verifyManifest(manifest(["published_at": timestamp])) } }
    }

    static func testCheck() throws {
        let raw = try manifest()
        FixtureURLProtocol.reset { request in
            try expect(request.url == LauncherUpdater.manifestURL, "check used caller endpoint")
            try expect(request.httpMethod == "GET" && request.httpBody == nil, "unexpected request body")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil, "credentials leaked into update request")
            return FixtureResponse(headers: ["Set-Cookie": "update-secret=ignore; Secure"], chunks: [raw])
        }
        let client = updater()
        let result = try awaitResult { client.check(completion: $0) }.get()
        try expect(result.available && result.version == "1.2.3", "check failed")
        let config = LauncherUpdater.isolatedConfiguration()
        try expect(config.httpCookieStorage == nil && !config.httpShouldSetCookies && config.urlCredentialStorage == nil && config.urlCache == nil, "session reuses shared state")
        try expect(config.httpAdditionalHeaders == nil, "session has extra headers")
    }

    static func testManifestTransport() throws {
        let raw = try manifest()
        let cases = [
            FixtureResponse(status: 302, headers: ["Location": fixtureURL.absoluteString], chunks: []),
            FixtureResponse(status: 500, chunks: []),
            FixtureResponse(headers: ["Content-Length": "262145"], chunks: []),
            FixtureResponse(chunks: [Data(repeating: 32, count: 262145)]),
            FixtureResponse(headers: ["Content-Encoding": "gzip"], chunks: [raw]),
        ]
        for response in cases {
            FixtureURLProtocol.reset { _ in response }
            let client = updater()
            let result = try awaitResult { client.check(completion: $0) }
            try expectFailure("manifest transport") { _ = try result.get() }
            try expect(FixtureURLProtocol.capturedRequests.count == 1, "automatic retry occurred")
        }
        FixtureURLProtocol.reset { _ in FixtureResponse(status: 302, redirect: URL(string: "https://evil.example/manifest")!) }
        let client = updater()
        let redirectResult = try awaitResult { client.check(completion: $0) }
        try expectFailure("manifest redirect") { _ = try redirectResult.get() }
        try expect(FixtureURLProtocol.capturedRequests.count == 1, "followed manifest redirect")
    }

    static func testAuthentication() throws {
        FixtureURLProtocol.reset { _ in FixtureResponse(authenticationChallenge: true) }
        let client = updater()
        let result = try awaitResult { client.check(completion: $0) }
        switch result {
        case .success: throw TestFailure.failed("accepted authenticated response")
        case .failure(let error):
            try expect(!(error is TestFailure), "updater attempted unsafe authentication handling")
        }
        try expect(FixtureURLProtocol.capturedRequests.count == 1, "authentication retried the request")
        try expect(LauncherUpdater.authenticationDisposition(for: NSURLAuthenticationMethodServerTrust) == .performDefaultHandling, "system TLS trust evaluation disabled")
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault] {
            try expect(LauncherUpdater.authenticationDisposition(for: method) == .cancelAuthenticationChallenge, "HTTP or client authentication not cancelled")
        }
    }

    static func testDownload() throws {
        let client = updater()
        let info = try client.verifyManifest(manifest())
        let destination = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: destination) }
        FixtureURLProtocol.reset { request in
            try expect(request.url == fixtureURL && request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil, "unsafe download request")
            return FixtureResponse(headers: ["Content-Length": String(fixtureAsset.count)], chunks: [fixtureAsset.prefix(4), fixtureAsset.dropFirst(4)])
        }
        let url = try awaitResult { client.download(info: info, destinationDirectory: destination, completion: $0) }.get()
        try expect(try Data(contentsOf: url) == fixtureAsset, "verified asset bytes differ")
        try expect(url.lastPathComponent == "SchylerAI-Image2-mcp-macOS.dmg", "unexpected retained filename")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        try expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "DMG is not private")
        try expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "download directory is not private")
    }

    static func testDownloadFailures() throws {
        let client = updater()
        let destination = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: destination) }
        let goodInfo = try client.verifyManifest(manifest())
        let badHashInfo = try client.verifyManifest(manifest(["sha256": String(repeating: "a", count: 64)]))
        let cases: [(LauncherUpdateInfo, FixtureResponse)] = [
            (badHashInfo, FixtureResponse(chunks: [fixtureAsset])),
            (goodInfo, FixtureResponse(chunks: [fixtureAsset.dropLast()])),
            (goodInfo, FixtureResponse(chunks: [fixtureAsset + Data([1])])),
            (goodInfo, FixtureResponse(headers: ["Content-Length": "19"], chunks: [fixtureAsset])),
            (goodInfo, FixtureResponse(status: 302, headers: ["Location": fixtureURL.absoluteString])),
            (goodInfo, FixtureResponse(status: 403)),
        ]
        for (info, response) in cases {
            FixtureURLProtocol.reset { _ in response }
            let result = try awaitResult { client.download(info: info, destinationDirectory: destination, completion: $0) }
            try expectFailure("invalid asset") { _ = try result.get() }
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "failed asset was retained")
        }
        FixtureURLProtocol.reset { _ in FixtureResponse(status: 302, redirect: URL(string: "https://evil.example/asset")!) }
        let redirected = try awaitResult { client.download(info: goodInfo, destinationDirectory: destination, completion: $0) }
        try expectFailure("asset redirect") { _ = try redirected.get() }
        try expect(FixtureURLProtocol.capturedRequests.count == 1, "followed asset redirect")
        let otherClient = LauncherUpdater(currentVersion: "1.2.2")
        let untrusted = try awaitResult { otherClient.download(info: goodInfo, destinationDirectory: destination, completion: $0) }
        try expectFailure("info from untrusted signer") { _ = try untrusted.get() }
    }

    static func testCancellationAndTimeouts() throws {
        let destination = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: destination) }
        let client = updater()
        let info = try client.verifyManifest(manifest())
        FixtureURLProtocol.reset { _ in FixtureResponse(chunks: [fixtureAsset.prefix(4)], stallsAfterChunks: true) }
        var completions = 0
        let cancelled = try awaitResult { completion in
            client.download(info: info, destinationDirectory: destination) { value in completions += 1; completion(value) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { client.cancel() }
        }
        try expectFailure("cancelled download") { _ = try cancelled.get() }
        try expect(completions == 1, "cancel completion count is wrong")
        try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "cancelled asset retained")
        for limits in [LauncherUpdateLimits(idleTimeout: 0.04, overallTimeout: 1), LauncherUpdateLimits(idleTimeout: 1, overallTimeout: 0.04)] {
            let timed = updater(limits: limits)
            let timedInfo = try timed.verifyManifest(manifest())
            FixtureURLProtocol.reset { _ in FixtureResponse(chunks: [fixtureAsset.prefix(4)], stallsAfterChunks: true) }
            let result = try awaitResult { timed.download(info: timedInfo, destinationDirectory: destination, completion: $0) }
            try expectFailure("timeout") { _ = try result.get() }
            try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "timed out asset retained")
        }
        FixtureURLProtocol.reset { _ in FixtureResponse(stalls: true) }
        var firstDone = false
        client.check { _ in firstDone = true }
        let busy = try awaitResult { client.check(completion: $0) }
        try expectFailure("concurrent operation") { _ = try busy.get() }
        client.cancel()
        let deadline = Date().addingTimeInterval(1)
        while !firstDone && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        try expect(firstDone, "cancel did not finish busy operation")
    }
}
