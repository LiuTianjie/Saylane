import Foundation
import CryptoKit

struct RimeDictionaryVersion: Equatable, Sendable {
    let revision: String
    var shortRevision: String { String(revision.prefix(8)) }
}

struct RimeDictionaryUpdateResult: Equatable, Sendable {
    let current: RimeDictionaryVersion
    let latest: RimeDictionaryVersion
    let changedTables: [String]
    let checkedAt: Date
    var hasUpdate: Bool { !changedTables.isEmpty }
    // Construct links ourselves; never open a server-supplied URL.
    var releaseURL: URL {
        URL(string: "https://github.com/iDvel/rime-ice/tree/\(latest.revision)/cn_dicts")!
    }
}

enum RimeDictionaryUpdateError: LocalizedError {
    case localData, invalidResponse, rateLimited, http(Int)
    var errorDescription: String? {
        switch self {
        case .localData: return "无法读取当前词库版本或词表，请重新安装应用后再检查。"
        case .invalidResponse: return "词库服务器返回的数据不完整，请稍后重试。"
        case .rateLimited: return "GitHub 暂时限制了检查频率，请稍后重试。"
        case .http(let status): return "检查失败（HTTP \(status)），请稍后重试。"
        }
    }
}

protocol RimeDictionaryChecking: Sendable {
    func check(resource: URL) async throws -> RimeDictionaryUpdateResult
}

/// Read-only, explicitly user-initiated check. Does not change schemas, native
/// runtime, user dictionaries, dependencies.lock.json or the app bundle.
struct RimeDictionaryUpdateService: RimeDictionaryChecking {
    static let tables = ["8105", "base", "ext", "others"]
    private static let apiRoot = "https://api.github.com/repos/iDvel/rime-ice"
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    private struct Lock: Decodable {
        let ice_commit: String
        let assets: [Asset]
        struct Asset: Decodable { let file: String; let sha256: String }
    }
    private struct Commit: Decodable { let sha: String }
    private struct Entry: Decodable { let name: String; let path: String; let type: String; let sha: String }

    static func isRevision(_ string: String) -> Bool {
        string.utf8.count == 40 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func installedVersion(resource: URL) throws -> RimeDictionaryVersion {
        let lock = try loadLock(resource)
        return RimeDictionaryVersion(revision: lock.ice_commit)
    }

    private static func loadLock(_ resource: URL) throws -> Lock {
        do {
            let data = try Data(contentsOf: resource.appendingPathComponent("dependencies.lock.json"))
            let lock = try JSONDecoder().decode(Lock.self, from: data)
            guard isRevision(lock.ice_commit) else { throw RimeDictionaryUpdateError.localData }
            return lock
        } catch { throw RimeDictionaryUpdateError.localData }
    }

    // SHA-1 is Git's blob identifier, not the authenticity/security checksum.
    // SHA-256 from the installed manifest is separately validated below.
    static func gitBlobID(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func check(resource: URL) async throws -> RimeDictionaryUpdateResult {
        // Non-actor async method keeps file verification off the UI main actor.
        try Task.checkCancellation()
        let lock = try Self.loadLock(resource)
        let current = RimeDictionaryVersion(revision: lock.ice_commit)
        let commits: [Commit] = try await request("/commits?sha=main&per_page=1")
        guard let head = commits.first, Self.isRevision(head.sha) else { throw RimeDictionaryUpdateError.invalidResponse }
        let latest = RimeDictionaryVersion(revision: head.sha)
        if latest == current {
            return RimeDictionaryUpdateResult(current: current, latest: latest, changedTables: [], checkedAt: Date())
        }
        // Pin the directory query to the observed commit, so a moving main branch
        // cannot mix metadata from two different revisions.
        let entries: [Entry] = try await request("/contents/cn_dicts?ref=\(latest.revision)")
        var changed: [String] = []
        for table in Self.tables {
            try Task.checkCancellation()
            let name = "\(table).dict.yaml"
            let matches = entries.filter { $0.name == name }
            guard matches.count == 1, let remote = matches.first,
                  remote.type == "file", remote.path == "cn_dicts/\(name)", Self.isRevision(remote.sha) else {
                throw RimeDictionaryUpdateError.invalidResponse
            }
            let assets = lock.assets.filter { $0.file == name }
            guard assets.count == 1, let asset = assets.first else { throw RimeDictionaryUpdateError.localData }
            let local: Data
            do { local = try Data(contentsOf: resource.appendingPathComponent("cn_dicts/\(name)"), options: .mappedIfSafe) }
            catch { throw RimeDictionaryUpdateError.localData }
            let checksum = SHA256.hash(data: local).map { String(format: "%02x", $0) }.joined()
            guard checksum == asset.sha256 else { throw RimeDictionaryUpdateError.localData }
            if Self.gitBlobID(local) != remote.sha { changed.append(table) }
        }
        try Task.checkCancellation()
        return RimeDictionaryUpdateResult(current: current, latest: latest, changedTables: changed, checkedAt: Date())
    }

    private func request<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: Self.apiRoot + path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Saylane-Dictionary-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https", response.url?.host == "api.github.com" else {
            throw RimeDictionaryUpdateError.invalidResponse
        }
        if response.statusCode == 429 || response.statusCode == 403 {
            throw RimeDictionaryUpdateError.rateLimited
        }
        guard response.statusCode == 200 else { throw RimeDictionaryUpdateError.http(response.statusCode) }
        guard data.count <= 1_048_576 else { throw RimeDictionaryUpdateError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RimeDictionaryUpdateError.invalidResponse }
    }
}
