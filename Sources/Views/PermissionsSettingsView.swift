import SwiftUI

/// Dedicated permission checklist. Each closed item opens the matching System Settings pane.
struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model
    var requiredOnly = false

    private var imeReady: Bool { model.inputSourceEnabled }
    private var micReady: Bool { model.permissions.microphone == .granted }
    private var speechReady: Bool { model.permissions.speechRecognition == .granted }
    private var monitoringReady: Bool { model.permissions.inputMonitoringGranted }
    private var screenReady: Bool { model.permissions.screenCaptureGranted }

    var body: some View {
        SettingsSection {
            if !model.installationPathValid {
                Label("这是未安装的构建副本，请先用安装包安装。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12.5))
            }
            permissionRow(
                symbol: "keyboard",
                title: "输入法",
                detail: imeDetail,
                ready: imeReady,
                busy: model.isActivatingInputSource,
                actionTitle: model.isActivatingInputSource ? "等待确认…" : "去开通",
                disabled: model.isActivatingInputSource
            ) {
                model.openInputMethodPermission()
            }
            permissionRow(
                symbol: "mic.fill",
                title: "麦克风",
                detail: micDetail,
                ready: micReady,
                busy: model.permissions.isRequestingMicrophone,
                actionTitle: model.permissions.isRequestingMicrophone ? "等待授权…" : "去开通",
                disabled: model.permissions.isRequestingMicrophone
            ) {
                Task { await model.requestMicrophonePermission() }
            }
        } header: {
            Text("必需")
        } footer: {
            Text(imeReady && micReady
                 ? "说话和拼音所需权限已开启。"
                 : "点「去开通」会打开对应的系统设置。")
        }

        if !requiredOnly {
            SettingsSection {
                permissionRow(
                    symbol: "waveform",
                    title: "语音识别",
                    detail: speechDetail,
                    ready: speechReady,
                    optional: true,
                    busy: model.permissions.isRequestingSpeech,
                    actionTitle: model.permissions.isRequestingSpeech ? "等待授权…" : "去开通",
                    disabled: model.permissions.isRequestingSpeech
                ) {
                    Task { await model.requestSpeechRecognitionPermission() }
                }
                permissionRow(
                    symbol: "hand.raised.fill",
                    title: "输入监控",
                    detail: monitoringDetail,
                    ready: model.globalHotkeyActive,
                    optional: true,
                    actionTitle: monitoringReady ? "重新接入" : "去开通"
                ) {
                    model.requestInputMonitoring()
                }
                permissionRow(
                    symbol: "rectangle.dashed",
                    title: "屏幕录制",
                    detail: screenReady ? "只截你划出的区域" : "划区翻译需要这项权限",
                    ready: screenReady,
                    optional: true,
                    actionTitle: "去开通"
                ) {
                    model.requestScreenCapturePermission()
                }
            } header: {
                Text("可选")
            } footer: {
                Text("语音识别在使用 Apple 识别时需要。输入监控让其它输入法下也能按快捷键。屏幕录制只用于划区翻译。")
            }

        }
    }

    private var imeDetail: String {
        if !model.installationPathValid { return "请先用安装包安装" }
        if imeReady { return model.inputSourceSelected ? "已选中 Saylane" : "已启用，按快捷键会自动选中" }
        if model.inputSourceInstalled { return "系统设置 → 键盘 → 输入法" }
        return "系统还没发现组件"
    }

    private var micDetail: String {
        switch model.permissions.microphone {
        case .granted: return "仅听写时采集"
        case .denied: return "系统设置 → 隐私与安全性 → 麦克风"
        case .notDetermined: return "只在按住说话时使用"
        }
    }

    private var speechDetail: String {
        switch model.permissions.speechRecognition {
        case .granted: return "使用 Apple 语音识别时需要"
        case .denied: return "系统设置 → 隐私与安全性 → 语音识别"
        case .notDetermined: return "使用 Apple 语音识别时需要"
        }
    }

    private var monitoringDetail: String {
        if model.globalHotkeyActive { return "其它输入法下也能按快捷键" }
        if monitoringReady { return "权限已开，监听还没接上" }
        return "系统设置 → 隐私与安全性 → 输入监控"
    }

    private func permissionRow(symbol: String, title: String, detail: String,
                               ready: Bool, optional: Bool = false, busy: Bool = false,
                               actionTitle: String, disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if optional {
                        Text("可选")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.fill, in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if ready {
                StatusText(text: "已开启", ready: true)
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
        .accessibilityElement(children: .combine)
    }
}
