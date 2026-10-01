import Foundation

enum SpeechEngineError: LocalizedError {
    case unsupportedLocale
    case invalidFormat
    case setupFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: return String(localized: "当前系统没有该语言的端侧语音模型。")
        case .invalidFormat: return String(localized: "无法匹配麦克风与语音识别的音频格式。")
        case .setupFailed: return String(localized: "语音识别启动失败。")
        }
    }
}


/// The recognizer cannot accept more audio for this utterance. The session
/// finalizes what was heard instead of failing.
struct SpeechLengthLimitReached: LocalizedError {
    var errorDescription: String? { String(localized: "本地模型单次最多识别 30 秒，已保留听到的部分。") }
}
