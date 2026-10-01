import Foundation

/// Process-wide Rime service. InputMethodKit and the candidate UI call it on the
/// main thread. The native engine owns decoding, ranking and persistent learning.
final class RimeRuntime: @unchecked Sendable {
    enum SetupError: LocalizedError {
        case missingData(String), initialization, schema
        var errorDescription: String? {
            switch self {
            case .missingData(let path): return String(localized: "缺少拼音资源：\(path)")
            case .initialization: return String(localized: "librime 初始化失败")
            case .schema: return String(localized: "Rime 拼音方案加载失败")
            }
        }
    }
    static let shared: Result<RimeRuntime, Error> = Result {
        let resource = Bundle.main.resourceURL?.appendingPathComponent("Rime", isDirectory: true)
        guard let resource else { throw SetupError.missingData("Rime") }
        let user = AppDirectories.rime
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
        for name in ["opencc/emoji.json", "opencc/emoji.txt", "opencc/others.txt"] {
            let file = sharedData.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { throw SetupError.missingData(file.path) }
        }
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        self.userData = userData
        guard SLRimeInitialize(sharedData.path, userData.path) != 0 else { throw SetupError.initialization }
    }

    func makeSession(fuzzy: Bool) throws -> SLSession {
        let session = SLRimeCreate(schema(fuzzy: fuzzy))
        guard session != 0 else { throw SetupError.schema }
        return session
    }

    /// The whole-sentence language model the user may download from the
    /// settings. It lives next to the user dictionary; nothing ships it.
    static let languageModelFile = "wanxiang-lts-zh-hans.gram"
    var languageModelInstalled: Bool {
        FileManager.default.fileExists(atPath: userData.appendingPathComponent(Self.languageModelFile).path)
    }

    /// The schema to type with. The variants that read the language model are
    /// chosen only while its file is there: the plain ones stay exactly as
    /// they were, and nothing looks for a file that does not exist.
    func schema(fuzzy: Bool) -> String {
        (fuzzy ? "saylane_pinyin_fuzzy" : "saylane_pinyin") + (languageModelInstalled ? "_lm" : "")
    }
}
