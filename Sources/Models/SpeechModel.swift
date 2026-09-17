import Foundation

enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case apple
    case senseVoice = "sensevoice-small-q8"
    case funASRNano = "fun-asr-nano-q4"
    case qwen4bit = "qwen3-asr-0.6b-4bit"
    case qwen6bit = "qwen3-asr-0.6b-6bit"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: return "Apple 系统识别"
        case .senseVoice: return "SenseVoiceSmall · Q8（试用）"
        case .funASRNano: return "Fun-ASR-Nano · Q4（试用）"
        case .qwen4bit: return "Qwen3-ASR 0.6B · 4-bit"
        case .qwen6bit: return "Qwen3-ASR 0.6B · 6-bit"
        }
    }
    var detail: String {
        switch self {
        case .apple: return "系统管理 · 实时组字"
        case .senseVoice: return "约 254 MB · 中英粤日韩 · 边说边出字"
        case .funASRNano: return "约 954 MB · 中英日 · 松开后出字"
        case .qwen4bit: return "约 724 MB · 较小体积 · 松开后出字"
        case .qwen6bit: return "约 873 MB · 较低量化损失 · 松开后出字"
        }
    }
    var isQwen: Bool { self == .qwen4bit || self == .qwen6bit }
    var isLocal: Bool { self != .apple }
    var isNative: Bool { self == .senseVoice || self == .funASRNano }
    var emitsLivePartial: Bool { self == .senseVoice }
    var repository: String {
        switch self {
        case .apple: return ""
        case .senseVoice: return "FunAudioLLM/SenseVoiceSmall-GGUF"
        case .funASRNano: return "FunAudioLLM/Fun-ASR-Nano-GGUF"
        case .qwen4bit: return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case .qwen6bit: return "mlx-community/Qwen3-ASR-0.6B-6bit"
        }
    }
    func supports(locale: Locale) -> Bool {
        let code = locale.language.languageCode?.identifier ?? ""
        if self == .senseVoice { return ["zh", "en", "yue", "ja", "ko"].contains(code) }
        if self == .funASRNano { return ["zh", "en", "ja"].contains(code) }
        return true
    }

    func manifest(in bundle: Bundle = .main) throws -> ASRModelManifest {
        guard isLocal,
              let url = bundle.url(forResource: rawValue, withExtension: "json", subdirectory: "ASR")
                ?? bundle.url(forResource: rawValue, withExtension: "json") else {
            throw ASRModelError.manifest
        }
        let result = try JSONDecoder().decode(ASRModelManifest.self, from: Data(contentsOf: url))
        try result.validate()
        guard result.id == rawValue else { throw ASRModelError.manifest }
        return result
    }
}

struct ASRModelManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let name: String
        let size: Int64
        let sha256: String
        let repository: String?
        let revision: String?
    }
    let id: String
    let repository: String
    let revision: String
    let license: String
    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func validate() throws {
        guard let model = SpeechModel(rawValue: id), model.isLocal,
              repository == model.repository,
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              !files.isEmpty, Set(files.map(\.name)).count == files.count,
              (model.isNative
                ? Set(files.map(\.name)) == (model == .senseVoice ? ["sensevoice-small-q8.gguf"] : ["funasr-encoder-f16.gguf", "qwen3-0.6b-q4km.gguf"])
                : files.contains(where: { $0.name == "model.safetensors" })),
              files.allSatisfy({ file in
                  !file.name.isEmpty && file.name != "." && file.name != ".."
                    && !file.name.contains("/") && !file.name.contains("\\")
                    && !file.name.hasPrefix(".") && file.name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil && file.size > 0 && file.size < 2_000_000_000
                    && ((file.repository == nil && file.revision == nil)
                        || (file.name == "tokenizer.json" && file.repository == "Qwen/Qwen3-ASR-0.6B-hf"
                            && file.revision == "7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c"))
                    && file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
              }) else { throw ASRModelError.manifest }
    }

    func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(file.repository ?? repository)/resolve/\(file.revision ?? revision)/\(file.name)")!
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RTranslate/ASRModels", isDirectory: true)
    }

    func directory(root: URL = Self.root) -> URL {
        root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(revision, isDirectory: true)
    }

    func isInstalled(root: URL = Self.root) -> Bool {
        let dir = directory(root: root)
        guard (try? String(contentsOf: dir.appendingPathComponent(".complete"), encoding: .utf8)) == revision else { return false }
        return files.allSatisfy { file in
            let values = try? dir.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true && Int64(values?.fileSize ?? -1) == file.size
        }
    }
}

enum ASRModelError: LocalizedError {
    case manifest, missing, diskSpace, invalidDownload(String), checksum(String), tooLong, unsupportedLanguage
    var errorDescription: String? {
        switch self {
        case .manifest: return "语音模型清单缺失或无效，请重新安装应用。"
        case .missing: return "请先在设置中下载并准备所选本地模型。"
        case .diskSpace: return "磁盘空间不足，请腾出足够空间后重试。"
        case .invalidDownload(let name): return "模型文件下载失败（\(name)），请检查网络后重试。"
        case .checksum(let name): return "模型文件校验失败（\(name)），请重新下载修复。"
        case .tooLong: return "本地模型当前每次最多识别 30 秒，请分成短句输入。本次未提交。"
        case .unsupportedLanguage: return "当前识别模型尚不支持所选语言。"
        }
    }
}

/// Explicit language hints; Chinese script conversion happens only after recognition.
enum QwenLanguage {
    static func name(for locale: Locale) throws -> String {
        let names = ["zh": "Chinese", "en": "English", "ja": "Japanese", "ko": "Korean",
                     "fr": "French", "es": "Spanish", "de": "German"]
        guard let code = locale.language.languageCode?.identifier, let name = names[code] else {
            throw ASRModelError.unsupportedLanguage
        }
        return name
    }

    static func normalize(_ text: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "zh" else { return text }
        let traditional = locale.language.script?.identifier == "Hant"
            || ["TW", "HK", "MO"].contains(locale.language.region?.identifier ?? "")
        return text.applyingTransform(StringTransform(traditional ? "Hans-Hant" : "Hant-Hans"), reverse: false) ?? text
    }
}

/// Keep personal vocabulary bounded; no application or document text is collected.
enum SpeechHotwords {
    /// One line of the user's vocabulary: "Saylane|赛兰|塞蓝" spells the term the way it should
    /// be written, then the ways recognizers tend to hear it.
    struct Entry: Equatable, Sendable {
        let canonical: String
        let aliases: [String]
    }

    static func entries(_ raw: String) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for line in raw.components(separatedBy: CharacterSet(charactersIn: "\n,，;；")) {
            let parts = line.components(separatedBy: CharacterSet(charactersIn: "|｜"))
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
                .filter { !$0.isEmpty }
            guard let canonical = parts.first, seen.insert(canonical).inserted else { continue }
            var aliases: [String] = []
            for alias in parts.dropFirst() where alias != canonical && !aliases.contains(alias) { aliases.append(alias) }
            result.append(Entry(canonical: canonical, aliases: aliases))
            if result.count == 50 { break }
        }
        return result
    }

    /// Recognizer bias uses only the canonical spellings.
    static func terms(_ raw: String) -> [String] { entries(raw).map(\.canonical) }

    static func context(_ raw: String) -> String? {
        let result = String(terms(raw).joined(separator: "、").prefix(1000))
        return result.isEmpty ? nil : result
    }
}
