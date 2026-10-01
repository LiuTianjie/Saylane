import Foundation

struct SetupReadiness {
    enum Blocker: Equatable {
        case microphoneNotRequested, microphoneDenied, inputMethodNotEnabled, modelsChecking, modelsMissing
        var message: String {
            switch self {
            case .microphoneNotRequested: return String(localized: "还没有允许麦克风。请完成授权，然后回到输入框重新按住快捷键。")
            case .microphoneDenied: return String(localized: "麦克风权限未开启，无法录音。请在“隐私与安全性 → 麦克风”中允许 Saylane。")
            case .inputMethodNotEnabled: return String(localized: "输入法尚未启用，请先完成系统输入法添加。")
            case .modelsChecking: return String(localized: "正在准备当前语言的模型，请等待准备检查完成后重新按住快捷键。")
            case .modelsMissing: return String(localized: "当前语言的模型尚未就绪，请先下载模型，再开始听写。")
            }
        }
    }
    let microphoneGranted: Bool
    let microphoneNeverRequested: Bool
    let inputMethodEnabled: Bool
    let checkingModels: Bool
    let speechReady: Bool
    let translationReady: Bool
    /// What stops a dictation that was asked for. Another input method being
    /// the current one is not on the list: the talk key may not arrive then,
    /// but once it has (our own window, or the listener that works under every
    /// input method) there is a way to write the text.
    var blocker: Blocker? {
        if !microphoneGranted { return microphoneNeverRequested ? .microphoneNotRequested : .microphoneDenied }
        if !inputMethodEnabled { return .inputMethodNotEnabled }
        if checkingModels { return .modelsChecking }
        if !speechReady || !translationReady { return .modelsMissing }
        return nil
    }
}
