import Foundation

struct SetupReadiness {
    enum Blocker: Equatable {
        case microphoneNotRequested, microphoneDenied, inputMethodNotEnabled, inputMethodNotSelected, modelsChecking, modelsMissing
        var message: String {
            switch self {
            case .microphoneNotRequested: return "还没有允许麦克风。请完成授权，然后回到输入框重新按住快捷键。"
            case .microphoneDenied: return "麦克风权限未开启，无法录音。请在“隐私与安全性 → 麦克风”中允许 RTranslate。"
            case .inputMethodNotEnabled: return "输入法尚未启用，请先完成系统输入法添加。"
            case .inputMethodNotSelected: return "当前没有选中 RTranslate。若已允许输入监控，按住说话会自动切过来；否则请先手动切到 RTranslate。"
            case .modelsChecking: return "正在准备当前语言的模型，请等待准备检查完成后重新按住快捷键。"
            case .modelsMissing: return "当前语言的模型尚未就绪，请先下载模型，再开始听写。"
            }
        }
    }
    let microphoneGranted: Bool
    let microphoneNeverRequested: Bool
    let inputMethodEnabled: Bool
    let inputMethodSelected: Bool
    let checkingModels: Bool
    let speechReady: Bool
    let translationReady: Bool
    let globalInvokeAvailable: Bool
    var blocker: Blocker? {
        if !microphoneGranted { return microphoneNeverRequested ? .microphoneNotRequested : .microphoneDenied }
        if !inputMethodEnabled { return .inputMethodNotEnabled }
        if !inputMethodSelected && !globalInvokeAvailable { return .inputMethodNotSelected }
        if checkingModels { return .modelsChecking }
        if !speechReady || !translationReady { return .modelsMissing }
        return nil
    }
}
