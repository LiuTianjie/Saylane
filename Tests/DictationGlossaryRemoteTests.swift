import Foundation

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (Int, Data, String))?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    static func configure(_ next: @escaping @Sendable (URLRequest) throws -> (Int, Data, String)) {
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
            let (status, data, host) = try handler(request)
            let url = URL(string: "https://\(host)/w/api.php")!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct DictationGlossaryRemoteTests {
    private static func payload(_ titles: [String], host: String, more: String? = nil) -> (Int, Data, String) {
        let members: [[String: Any]] = titles.map { ["ns": 0, "title": $0] }
        var object: [String: Any] = ["query": ["categorymembers": members]]
        if let more { object["continue"] = ["cmcontinue": more, "continue": "-||"] }
        return (200, try! JSONSerialization.data(withJSONObject: object), host)
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let terms = try await DictationGlossaryClient(userAgent: "Saylane/test (https://github.com/LiuTianjie/Saylane; dictation-glossary-test)").fetch()
            precondition(terms.count >= 80, "live harvest too small: \(terms.count)")
            precondition(terms.contains("二次函数") || terms.contains("时间复杂度") || terms.contains("电子榨菜"))
            precondition(!terms.contains("翻译") && !terms.contains("计算") && !terms.contains("微信"))
            print("LIVE: terms=\(terms.count) sample=\(terms.prefix(8).joined(separator: "、"))")
            return
        }

        precondition(DictationGlossaryClient.isContinueToken("page|4a0ae5b9|446197"))
        precondition(!DictationGlossaryClient.isContinueToken("https://evil.example/"))
        precondition(!DictationGlossaryClient.isContinueToken(String(repeating: "a", count: 401)))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = DictationGlossaryClient(session: session, userAgent: "Saylane/test")

        MockProtocol.configure { request in
            precondition(request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "User-Agent") == "Saylane/test")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            let host = request.url!.host!
            precondition(DictationGlossaryClient.allowedHosts.contains(host))
            let category = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cmtitle" })?.value ?? ""
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cmcontinue" })?.value
            if category == "Category:数学术语" {
                if token == nil {
                    return Self.payload(["二次函数", "闭包 (数学)", "计算", "数据结构与算法术语列表"], host: host, more: "page|abc|1")
                }
                precondition(token == "page|abc|1")
                return Self.payload(["特征向量", "幾乎"], host: host)
            }
            if category == "Category:漢語網路用語" {
                return Self.payload(["电子榨菜", "yyds", "危", "233", "hi", "加速", "PUA", "内卷"], host: host)
            }
            if category == "Category:漢語 計算機科學" {
                return Self.payload(["時間複雜度", "翻译"], host: host)
            }
            return Self.payload([], host: host)
        }

        let terms = try await client.fetch()
        precondition(terms.contains("二次函数"))
        precondition(!terms.contains("闭包"))
        precondition(terms.contains("特征向量"))
        precondition(terms.contains("电子榨菜"))
        precondition(terms.contains("yyds"))
        precondition(terms.contains("PUA"))
        precondition(!terms.contains("内卷"))
        precondition(terms.contains("时间复杂度"))
        precondition(!terms.contains("计算"))
        precondition(!terms.contains("几乎"))
        precondition(!terms.contains("翻译"))
        precondition(!terms.contains("危"))
        precondition(!terms.contains("233"))
        precondition(!terms.contains("hi"))
        precondition(!terms.contains("加速"))
        precondition(MockProtocol.requests.count == DictationGlossaryClient.catalogs.count + 1)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saylane-glossary-\(UUID().uuidString)")
        let file = root.appendingPathComponent("dictation-glossary.json")
        defer { try? FileManager.default.removeItem(at: root) }

        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = DictationGlossaryStore(fileURL: file, client: client, clock: { now })
        precondition(store.terms.isEmpty)
        await store.refreshIfStale()
        precondition(store.terms.contains("二次函数"))
        precondition(store.terms.contains("电子榨菜"))
        precondition(!store.terms.contains("微积分"))
        let firstCount = MockProtocol.requests.count
        await store.refreshIfStale()
        precondition(MockProtocol.requests.count == firstCount)

        now = now.addingTimeInterval(DictationGlossaryClient.refreshInterval + 1)
        await store.refreshIfStale()
        precondition(MockProtocol.requests.count > firstCount)

        let reloaded = DictationGlossaryStore(fileURL: file, client: client, clock: { now })
        precondition(reloaded.terms.contains("二次函数"))
        precondition(reloaded.terms.contains("时间复杂度"))

        MockProtocol.configure { _ in throw URLError(.notConnectedToInternet) }
        now = now.addingTimeInterval(DictationGlossaryClient.refreshInterval + 1)
        await store.refreshIfStale()
        precondition(store.terms.contains("二次函数"))

        print("PASS: wikimedia harvest filter, daily cache, offline keeps last snapshot")
    }
}
