import SwiftUI

/// Dedicated permission checklist. Each closed item opens the matching System Settings pane.
/// `sequential` shows one open item at a time (onboarding); the settings page lists all.
struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model
    var requiredOnly = false
    var optionalOnly = false
    var sequential = false

    private var imeReady: Bool { model.readinessState.inputSource.enabled }
    private var micReady: Bool { model.permissions.microphone == .granted }
    private var speechReady: Bool { model.permissions.speechRecognition == .granted }
    private var screenReady: Bool { model.permissions.screenCaptureGranted }
    private var accessibilityReady: Bool { model.readinessState.permissions.accessibility }
    private var globalEventListening: Bool { model.router.isGlobalTapListening }
    private var globalEventFiltering: Bool { model.router.isGlobalTapFiltering }
    private var selectedHotkeyNeedsFiltering: Bool { !model.prefs.pushToTalk.isModifier }
    private var globalTriggerUsable: Bool {
        globalEventListening && (!selectedHotkeyNeedsFiltering || globalEventFiltering)
    }

    var body: some View {
        if !optionalOnly {
            SettingsSection {
                if !model.readinessState.inputSource.installedLocation {
                    Label(String(localized: "这是未安装的构建副本，请先用安装包安装。"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12.5))
                }
                permissionRow(
                    symbol: "keyboard",
                    title: String(localized: "输入法"),
                    detail: imeDetail,
                    why: String(localized: "Saylane 以输入法的方式把文字直接写进光标处，不用剪贴板。"),
                    ready: imeReady,
                    pending: sequential && !imeReady,
                    busy: model.isActivatingInputSource,
                    actionTitle: model.isActivatingInputSource ? String(localized: "等待确认…") : String(localized: "去开通"),
                    disabled: model.isActivatingInputSource
                ) {
                    model.openInputMethodPermission()
                }
                permissionRow(
                    symbol: "mic.fill",
                    title: String(localized: "麦克风"),
                    detail: micDetail,
                    why: String(localized: "只在你按住快捷键说话时采集，识别在本机完成。"),
                    ready: micReady,
                    pending: sequential && imeReady && !micReady,
                    locked: sequential && !imeReady,
                    busy: model.permissions.isRequestingMicrophone,
                    actionTitle: model.permissions.isRequestingMicrophone ? String(localized: "等待授权…") : String(localized: "去开通"),
                    disabled: model.permissions.isRequestingMicrophone
                ) {
                    Task { await model.requestMicrophonePermission() }
                }
            } header: {
                Text(String(localized: "必需"))
            } footer: {
                Text(imeReady && micReady
                     ? String(localized: "说话和拼音所需权限已开启。")
                     : String(localized: "点「去开通」会打开对应的系统设置；开启后这里会自动更新。"))
            }
        }

        if !requiredOnly {
            SettingsSection {
                permissionRow(
                    symbol: "accessibility",
                    title: String(localized: "辅助功能"),
                    detail: accessibilityDetail,
                    why: accessibilityWhy,
                    ready: accessibilityReady && globalEventFiltering,
                    recommended: true,
                    actionTitle: accessibilityReady ? String(localized: "重新接入") : String(localized: "去开通")
                ) {
                    if accessibilityReady { model.reconnectGlobalKeys() } else { model.requestAccessibility() }
                }
                permissionRow(
                    symbol: "waveform",
                    title: String(localized: "语音识别"),
                    detail: speechDetail,
                    why: String(localized: "使用 Apple 系统识别时需要；本地模型不需要。"),
                    ready: speechReady,
                    optional: true,
                    busy: model.permissions.isRequestingSpeech,
                    actionTitle: model.permissions.isRequestingSpeech ? String(localized: "等待授权…") : String(localized: "去开通"),
                    disabled: model.permissions.isRequestingSpeech
                ) {
                    Task { await model.requestSpeechRecognitionPermission() }
                }
                permissionRow(
                    symbol: "rectangle.dashed",
                    title: String(localized: "屏幕录制"),
                    detail: screenReady ? String(localized: "只截你划出的区域") : String(localized: "划区翻译需要这项权限"),
                    why: String(localized: "只用于截屏翻译，只截你划出的区域。"),
                    ready: screenReady,
                    optional: true,
                    actionTitle: String(localized: "去开通")
                ) {
                    model.requestScreenCapturePermission()
                }
            } header: {
                Text(String(localized: "推荐与可选"))
            } footer: {
                Text(optionalPermissionsFooter)
            }
        }
    }

    private var imeDetail: String {
        if !model.readinessState.inputSource.installedLocation { return String(localized: "请先用安装包安装") }
        if imeReady {
            if model.readinessState.inputSource.selected { return String(localized: "已选中 Saylane") }
            if globalTriggerUsable { return String(localized: "已启用，其它输入法下也能按快捷键说话") }
            return String(localized: "已启用；切到 Saylane 后可以打字和说话")
        }
        if model.readinessState.inputSource.installed { return String(localized: "系统设置 → 键盘 → 输入法") }
        return String(localized: "系统还没发现组件")
    }

    private var micDetail: String {
        switch model.permissions.microphone {
        case .granted: return String(localized: "仅听写时采集")
        case .denied: return String(localized: "系统设置 → 隐私与安全性 → 麦克风")
        case .notDetermined: return String(localized: "只在按住说话时使用")
        }
    }

    private var speechDetail: String {
        switch model.permissions.speechRecognition {
        case .granted: return String(localized: "使用 Apple 语音识别时需要")
        case .denied: return String(localized: "系统设置 → 隐私与安全性 → 语音识别")
        case .notDetermined: return String(localized: "使用 Apple 语音识别时需要")
        }
    }

    private var accessibilityWhy: String {
        if selectedHotkeyNeedsFiltering {
            return String(localized: "当前功能键需要辅助功能权限，才能拦截按键并可靠收到松开事件；也可以改用 Option、Command、Control、Shift 或 fn。")
        }
        return String(localized: "让快捷键在任何应用、任何输入法下都能用，并把文字直接写到光标处。不开启时，只有 Saylane 是当前输入法时才能说话。")
    }

    private var accessibilityDetail: String {
        if accessibilityReady {
            if !globalEventFiltering { return String(localized: "已允许；全局按键监听尚未接入") }
            return String(localized: "已允许，任何应用和输入法下都能按键说话")
        }
        if selectedHotkeyNeedsFiltering {
            return String(localized: "当前功能键需要这项权限")
        }
        return String(localized: "系统设置 → 隐私与安全性 → 辅助功能")
    }

    private var optionalPermissionsFooter: String {
        if selectedHotkeyNeedsFiltering {
            return String(localized: "当前功能键需要辅助功能权限；若不想开启，请改用 Option、Command、Control、Shift 或 fn。其它增强可以稍后开启。")
        }
        return String(localized: "都可以稍后在「权限管理」里开启。不开辅助功能时，在 Saylane 输入法下仍然可以说话和打字。")
    }

    private func permissionRow(symbol: String, title: String, detail: String, why: String,
                               ready: Bool, optional: Bool = false, recommended: Bool = false,
                               pending: Bool = false, locked: Bool = false,
                               busy: Bool = false, actionTitle: String, disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(ready ? Theme.accent : .secondary)
                .frame(width: 32, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if optional || recommended {
                        Text(recommended ? String(localized: "推荐") : String(localized: "可选"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.fill, in: Capsule())
                    }
                }
                Text(sequential && !ready ? why : detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if ready {
                StatusText(text: String(localized: "已开启"), ready: true)
            } else if locked {
                Text(String(localized: "先完成上一项")).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            } else {
                Button {
                    action()
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(disabled)
            }
        }
        .padding(.vertical, 3)
        .opacity(locked ? 0.55 : 1)
        .overlay(alignment: .leading) {
            if pending {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 2).offset(x: -12)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
