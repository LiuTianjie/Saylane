import Foundation

enum SessionState: Equatable {
    case idle
    case preparing
    case listening
    case finalizing
    case polishing
    case cancelling
}

enum OverlayPhase: Equatable {
    case hidden
    case preparing
    case listening
    case finalizing
    case polishing
    case cancelling
    case error
}

/// Emitted only after the corresponding text has been committed.
enum CompletionFeedback: Equatable {
    case ordinary, polished, unchanged, polishFailed, polishTimedOut

    var message: String {
        switch self {
        case .ordinary: return "已输入 · 未启用 AI 润色"
        case .polished: return "已润色并输入"
        case .unchanged: return "AI 已检查，无需修改"
        case .polishFailed: return "AI 润色失败 · 已保留普通结果"
        case .polishTimedOut: return "AI 润色超时 · 已保留普通结果"
        }
    }
    var isWarning: Bool { self == .polishFailed || self == .polishTimedOut }
}
