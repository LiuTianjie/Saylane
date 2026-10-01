import Foundation

/// Daily harvest of Chinese Wikipedia / Wiktionary category titles (CC BY-SA).
/// Commercial cell dictionaries such as Sogou popular-word dumps are not used.
struct DictationGlossaryClient: Sendable {
    static let catalogs: [(host: String, category: String)] = [
        ("zh.wikipedia.org", "Category:数学术语"),
        ("zh.wikipedia.org", "Category:物理学术语"),
        ("zh.wikipedia.org", "Category:生物学术语"),
        ("zh.wikipedia.org", "Category:数据结构"),
        ("zh.wikipedia.org", "Category:算法"),
        ("zh.wiktionary.org", "Category:漢語 計算機科學"),
        ("zh.wiktionary.org", "Category:漢語 程式設計"),
        ("zh.wiktionary.org", "Category:漢語 生物化學"),
        ("zh.wiktionary.org", "Category:漢語網路用語"),
    ]
    static let allowedHosts: Set<String> = ["zh.wikipedia.org", "zh.wiktionary.org"]
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let maxTerms = 800

    private let session: URLSession
    private let userAgent: String

    init(session: URLSession? = nil, userAgent: String? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 45
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
        if let userAgent {
            self.userAgent = userAgent
        } else {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            self.userAgent = "Saylane/\(version) (https://github.com/LiuTianjie/Saylane; dictation-glossary)"
        }
    }

    func fetch() async throws -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        var succeeded = 0
        var lastError: Error?
        for catalog in Self.catalogs {
            do {
                let titles = try await members(host: catalog.host, category: catalog.category)
                succeeded += 1
                for title in titles {
                    guard let term = DictationGlossary.remoteTerm(fromTitle: title),
                          seen.insert(term).inserted else { continue }
                    terms.append(term)
                    if terms.count == Self.maxTerms { return terms }
                }
            } catch {
                lastError = error
            }
        }
        if succeeded == 0 { throw lastError ?? URLError(.cannotFindHost) }
        return terms
    }

    private func members(host: String, category: String) async throws -> [String] {
        guard Self.allowedHosts.contains(host) else { throw URLError(.badURL) }
        var titles: [String] = []
        var token: String?
        for _ in 0..<3 {
            var items = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "formatversion", value: "2"),
                URLQueryItem(name: "list", value: "categorymembers"),
                URLQueryItem(name: "cmtitle", value: category),
                URLQueryItem(name: "cmnamespace", value: "0"),
                URLQueryItem(name: "cmtype", value: "page"),
                URLQueryItem(name: "cmlimit", value: "500"),
            ]
            if let token {
                items.append(URLQueryItem(name: "cmcontinue", value: token))
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/w/api.php"
            components.queryItems = items
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "GET"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  response.url?.scheme == "https",
                  let responseHost = response.url?.host, Self.allowedHosts.contains(responseHost),
                  response.statusCode == 200, data.count <= 1_048_576 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(CategoryResponse.self, from: data)
            for member in decoded.query?.categorymembers ?? [] {
                if member.ns == nil || member.ns == 0 { titles.append(member.title) }
            }
            guard let next = decoded.continue?.cmcontinue, Self.isContinueToken(next) else { break }
            token = next
        }
        return titles
    }

    static func isContinueToken(_ token: String) -> Bool {
        (1...400).contains(token.utf8.count)
            && token.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "|-._".unicodeScalars.contains($0))
            }
    }

    private struct CategoryResponse: Decodable {
        struct Query: Decodable { var categorymembers: [Member] }
        struct Member: Decodable { var title: String; var ns: Int? }
        struct Continue: Decodable { var cmcontinue: String? }
        var query: Query?
        var `continue`: Continue?
    }
}

/// Cached on disk; refreshed in the background while the input method is running.
final class DictationGlossaryStore: @unchecked Sendable {
    static let shared = DictationGlossaryStore()

    static var defaultFileURL: URL { AppDirectories.glossaryFile }

    private struct Snapshot: Codable {
        var schema: Int
        var fetchedAt: TimeInterval
        var terms: [String]
    }

    private let fileURL: URL
    private let client: DictationGlossaryClient
    private let clock: () -> Date
    private let lock = NSLock()
    private var cached: [String] = []
    private var fetchedAt: Date?

    var terms: [String] {
        snapshot().terms
    }

    init(fileURL: URL = DictationGlossaryStore.defaultFileURL,
         client: DictationGlossaryClient = DictationGlossaryClient(),
         clock: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.client = client
        self.clock = clock
        loadFromDisk()
    }

    func refreshIfStale() async {
        let current = snapshot()
        if let fetchedAt = current.fetchedAt, clock().timeIntervalSince(fetchedAt) < DictationGlossaryClient.refreshInterval {
            return
        }
        do {
            let terms = try await client.fetch()
            try Task.checkCancellation()
            guard !terms.isEmpty else { return }
            persist(terms, at: clock())
        } catch {}
    }

    private func snapshot() -> (terms: [String], fetchedAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        return (cached, fetchedAt)
    }

    private func persist(_ terms: [String], at date: Date) {
        let remote = Self.cleaned(terms)
        guard !remote.isEmpty else { return }
        lock.lock()
        cached = remote
        fetchedAt = date
        lock.unlock()
        let snapshot = Snapshot(schema: 1, fetchedAt: date.timeIntervalSince1970, terms: remote)
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 512_000 else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {}
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL), data.count <= 512_000,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schema == 1 else { return }
        let now = clock().timeIntervalSince1970
        guard snapshot.fetchedAt > 1_600_000_000, snapshot.fetchedAt < now + 86_400 else { return }
        let remote = Self.cleaned(snapshot.terms)
        lock.lock()
        cached = remote
        fetchedAt = Date(timeIntervalSince1970: snapshot.fetchedAt)
        lock.unlock()
    }

    private static func cleaned(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var remote: [String] = []
        for title in terms {
            guard let term = DictationGlossary.remoteTerm(fromTitle: title), seen.insert(term).inserted else { continue }
            remote.append(term)
            if remote.count == DictationGlossaryClient.maxTerms { break }
        }
        return remote
    }
}
