import Foundation

/// Process-wide Rime service. InputMethodKit and the candidate UI call it on the
/// main thread. The native engine owns decoding, ranking and persistent learning.
final class RimeRuntime {
    enum SetupError: LocalizedError {
        case missingData(String), initialization, schema
        var errorDescription: String? {
            switch self {
            case .missingData(let path): return "缺少拼音资源：\(path)"
            case .initialization: return "librime 初始化失败"
            case .schema: return "Rime 拼音方案加载失败"
            }
        }
    }
    static let shared: Result<RimeRuntime, Error> = Result {
        let resource = Bundle.main.resourceURL?.appendingPathComponent("Rime", isDirectory: true)
        guard let resource else { throw SetupError.missingData("Rime") }
        let user = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("Saylane/Rime", isDirectory: true)
        return try RimeRuntime(sharedData: resource, userData: user)
    }
    let userData: URL
    var version: String { String(cString: SLRimeVersion()) }

    init(sharedData: URL, userData: URL) throws {
        for name in ["saylane_pinyin.schema.yaml", "saylane_pinyin_fuzzy.schema.yaml", "saylane.table.bin",
                     "saylane_pinyin.prism.bin", "saylane_pinyin_fuzzy.prism.bin", "melt_eng.table.bin",
                     "saylane_en.prism.bin", "saylane_en.schema.yaml"] {
            let file = sharedData.appendingPathComponent("build/\(name)")
            guard FileManager.default.fileExists(atPath: file.path) else { throw SetupError.missingData(file.path) }
        }
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        self.userData = userData
        guard SLRimeInitialize(sharedData.path, userData.path) != 0 else { throw SetupError.initialization }
    }

    func makeSession(fuzzy: Bool) throws -> SLSession {
        let session = SLRimeCreate(Self.schema(fuzzy: fuzzy))
        guard session != 0 else { throw SetupError.schema }
        return session
    }

    static func schema(fuzzy: Bool) -> String { fuzzy ? "saylane_pinyin_fuzzy" : "saylane_pinyin" }
}
