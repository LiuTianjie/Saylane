import SwiftUI

/// The trial field plus a live microphone meter, so the user sees the input
/// level before saying anything.
struct DictationTrialView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var meter = MicrophoneLevelMeter()
    /// Height of the text area; the welcome page uses a shorter one.
    var height: CGFloat = 140

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: model.isListening ? "waveform" : "text.cursor")
                    .foregroundStyle(Theme.accent)
                Text(model.isListening ? String(localized: "正在听你说…") : String(localized: "语音试用区"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(model.currentDirection.compactTitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if model.testText.isEmpty {
                    Text(String(localized: "点这里，说说你今天的计划…"))
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $model.testText)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .frame(height: height)
                    .accessibilityLabel(String(localized: "听写测试输入框"))
                    .allowsHitTesting(!model.isListening)
            }
            .font(.system(size: 17))
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Keycap(text: model.prefs.pushToTalk.shortLabel, compact: true)
                Text(model.isListening ? String(localized: "正在识别…") : model.prefs.tapToTalk ? String(localized: "点按开始，再按任意键提交") : String(localized: "按住说话，松开提交"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                MicrophoneLevelBar(level: model.isListening ? model.voice.overlay.model.level : meter.level,
                                   active: meter.isRunning || model.isListening)
                Button(String(localized: "清空")) { model.clearTestText() }.buttonStyle(.plain)
                    .foregroundStyle(.secondary).disabled(model.isListening || model.testText.isEmpty)
            }
        }
        .padding(22)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.hairline))
        .onAppear {
            model.setDictationTrialVisible(true)
            if model.isVoiceTrialActive, model.permissions.microphone == .granted { meter.start() }
        }
        .onDisappear { model.setDictationTrialVisible(false); meter.stop() }
        .onChange(of: model.isListening) { _, listening in
            if listening { meter.stop() } else if model.isVoiceTrialActive, model.permissions.microphone == .granted { meter.start() }
        }
        .onChange(of: model.permissions.microphone) { _, status in
            if status == .granted, model.isVoiceTrialActive, !model.isListening { meter.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in meter.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in meter.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if model.isVoiceTrialActive, model.permissions.microphone == .granted, !model.isListening { meter.start() }
        }
    }
}

private struct MicrophoneLevelBar: View {
    let level: Float
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic").font(.system(size: 11)).foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                }
            }
            .frame(width: 72, height: 6)
            .animation(.easeOut(duration: 0.08), value: level)
        }
        .help(String(localized: "麦克风电平：说话时应当跳动"))
        .accessibilityLabel(String(localized: "麦克风电平"))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard active else { return String(localized: "未启用") }
        switch max(0, min(1, level)) {
        case ..<0.05: return String(localized: "无输入")
        case ..<0.20: return String(localized: "较弱")
        case ..<0.78: return String(localized: "正常")
        default: return String(localized: "较强")
        }
    }
}
