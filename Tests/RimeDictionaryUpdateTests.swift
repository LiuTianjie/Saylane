import Foundation
import CryptoKit

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?
    private static var seen: [URLRequest] = []
    static func configure(_ next: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handler = next; seen = []
    }
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let handler = Self.handler!
        Self.lock.unlock()
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor GatedChecker: RimeDictionaryChecking {
    private var pending: [CheckedContinuation<RimeDictionaryUpdateResult, Error>] = []
    private(set) var calls = 0
    func check(resource: URL) async throws -> RimeDictionaryUpdateResult {
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ result: RimeDictionaryUpdateResult) {
        pending.removeFirst().resume(returning: result)
    }
}

@main struct RimeDictionaryUpdateTests {
    static let old = String(repeating: "a", count: 40)
    static let new = String(repeating: "b", count: 40)

    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--live" {
            let result = try await RimeDictionaryUpdateService().check(resource: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("LIVE: current=\(result.current.shortRevision), upstream=\(result.latest.shortRevision), changed=\(result.changedTables)")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saylane-dictionary-check-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cn_dicts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var assets: [[String: String]] = []
        var entries: [[String: String]] = []
        for table in RimeDictionaryUpdateService.tables {
            let name = "\(table).dict.yaml"
            let bytes = Data("你好\tni hao\t100\n\(table)\n".utf8)
            try bytes.write(to: root.appendingPathComponent("cn_dicts/\(name)"))
            assets.append(["file": name, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()])
            entries.append(["name": name, "path": "cn_dicts/\(name)", "type": "file", "sha": RimeDictionaryUpdateService.gitBlobID(bytes)])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["ice_commit": old, "assets": assets])
        try manifest.write(to: root.appendingPathComponent("dependencies.lock.json"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = RimeDictionaryUpdateService(session: session)
        precondition(RimeDictionaryUpdateService.gitBlobID(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        precondition(!RimeDictionaryUpdateService.isRevision("../invalid"))
        precondition(!RimeDictionaryUpdateService.isRevision(String(repeating: "g", count: 40)))

        MockProtocol.configure { _ in (200, Data("[{\"sha\":\"\(old)\"}]".utf8)) }
        var result = try await service.check(resource: root)
        precondition(!result.hasUpdate && MockProtocol.requests.count == 1)

        func setup(_ entries: [[String: String]]) {
            MockProtocol.configure { request in
                precondition(request.url?.host == "api.github.com")
                precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
                precondition(request.httpMethod == "GET")
                if request.url!.path.hasSuffix("/commits") {
                    return (200, Data("[{\"sha\":\"\(new)\"}]".utf8))
                }
                precondition(request.url?.query == "ref=\(new)")
                return (200, try JSONSerialization.data(withJSONObject: entries))
            }
        }
        // Repository changes (including unused Tencent/large character tables)
        // do not imply the four bundled dictionaries changed.
        setup(entries + [["name": "tencent.dict.yaml", "path": "cn_dicts/tencent.dict.yaml", "type": "file", "sha": old]])
        result = try await service.check(resource: root)
        precondition(!result.hasUpdate && result.latest.revision == new)
        precondition(MockProtocol.requests.count == 2)
        var changed = entries
        changed[1]["sha"] = new
        setup(changed)
        result = try await service.check(resource: root)
        precondition(result.changedTables == ["base"])
        precondition(result.releaseURL.absoluteString == "https://github.com/iDvel/rime-ice/tree/\(new)/cn_dicts")
        let unchanged = try Data(contentsOf: root.appendingPathComponent("dependencies.lock.json"))
        precondition(unchanged == manifest)

        setup(Array(entries.dropLast()))
        await mustFail(service, root, contains: "不完整")
        setup(entries + [entries[0]])
        await mustFail(service, root, contains: "不完整")
        var malformed = entries
        malformed[0]["sha"] = "bad"
        setup(malformed)
        await mustFail(service, root, contains: "不完整")
        for (status, text) in [(403, "频率"), (429, "频率"), (500, "HTTP 500")] {
            MockProtocol.configure { _ in (status, Data()) }
            await mustFail(service, root, contains: text)
        }
        MockProtocol.configure { _ in (200, Data("not json".utf8)) }
        await mustFail(service, root, contains: "不完整")
        MockProtocol.configure { _ in (200, Data("[{\"sha\":\"../../bad\"}]".utf8)) }
        await mustFail(service, root, contains: "不完整")
        MockProtocol.configure { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await service.check(resource: root); preconditionFailure("offline accepted") }
        catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        setup(entries)
        try Data("corrupted".utf8).write(to: root.appendingPathComponent("cn_dicts/base.dict.yaml"))
        await mustFail(service, root, contains: "当前词库")

        // Coalesce repeated clicks and ignore a cancelled old result after retry.
        let gate = GatedChecker()
        let model = RimeDictionaryUpdateModel(resource: root, checker: gate)
        precondition(model.currentVersion == String(old.prefix(8)))
        let initialCalls = await gate.calls
        precondition(initialCalls == 0) // constructing UI performs no request
        model.check(); model.check()
        while await gate.calls < 1 { await Task.yield() }
        let coalescedCalls = await gate.calls
        precondition(coalescedCalls == 1)
        model.cancel()
        precondition(model.state == .idle)
        model.check()
        while await gate.calls < 2 { await Task.yield() }
        await gate.finish(result)
        for _ in 0..<20 { await Task.yield() }
        precondition(model.isChecking)
        await gate.finish(result)
        while model.isChecking { await Task.yield() }
        precondition(model.result == result)
        MockProtocol.configure { _ in throw URLError(.timedOut) }
        let timeout = RimeDictionaryUpdateModel(resource: root, checker: service)
        timeout.check()
        while timeout.isChecking { await Task.yield() }
        precondition(timeout.statusText.contains("超时"))
        print("PASS: manual dictionary update check, pinned revision, four-table comparison, no writes, malformed data, rate limit, offline, timeout, cancellation and duplicate clicks")
    }
    static func mustFail(_ service: RimeDictionaryUpdateService, _ root: URL, contains: String) async {
        do { _ = try await service.check(resource: root); preconditionFailure("unexpected success") }
        catch { precondition(error.localizedDescription.contains(contains), error.localizedDescription) }
    }
}
