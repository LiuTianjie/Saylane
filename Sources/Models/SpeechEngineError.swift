import Foundation

enum SpeechEngineError: LocalizedError {
    case unsupportedLocale
    case invalidFormat
    case setupFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: return "当前系统没有该语言的端侧语音模型。"
        case .invalidFormat: return "无法匹配麦克风与语音识别的音频格式。"
        case .setupFailed: return "语音识别启动失败。"
        }
    }
}

