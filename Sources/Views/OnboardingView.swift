import SwiftUI

/// First run: welcome → required permissions, one at a time → optional extras → try it.
/// Presentation state stays separate from the persisted onboarding version; becoming
/// ready must not dismiss the guide while the user is reading it.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Int

    init(initialStep: Int = 0) {
        _step = State(initialValue: initialStep)
    }
    private let titles = [String(localized: "欢迎使用"), String(localized: "开启权限"), String(localized: "可选增强"), String(localized: "试一下")]
    private var permissionsReady: Bool { model.readinessState.requiredSetupComplete }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SaylaneBrand()
                Spacer()
                Button(String(localized: "稍后设置")) { model.deferSetup() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .selfTestAnchor("setup-later")
            }
            .padding(.horizontal, 36).padding(.top, 24)

            HStack(spacing: 14) {
                ForEach(0..<4) { index in
                    HStack(spacing: 7) {
                        ZStack {
                            Circle().fill(index <= step ? Theme.accent : Theme.fillStrong).frame(width: 22, height: 22)
                            if index < step {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(index == step ? Color.white : Color.secondary)
                            }
                        }
                        Text(titles[index]).font(.system(size: 12, weight: index == step ? .semibold : .regular))
                            .foregroundStyle(index == step ? Color.primary : Color.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "第 \(index + 1) 步，共 4 步：\(titles[index])"))
                    .accessibilityValue(progressAccessibilityValue(for: index))
                    .accessibilityAddTraits(index == step ? .isSelected : [])
                    if index != 3 {
                        Rectangle().fill(Theme.hairlineStrong).frame(width: 34, height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "设置进度"))
            .padding(.top, 30).padding(.bottom, 24)
            ScrollView {
                VStack(spacing: 22) {
                    if let notice = model.notice, notice.level == .actionable {
                        Text(notice.message).font(.system(size: 12)).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    switch step {
                    case 0: welcome
                    case 1: permissions.selfTestAnchor("setup-permissions")
                    case 2: optional
                    default: trial
                    }
                }
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .padding(.horizontal, 36).padding(.bottom, 24)
            }
            HStack {
                if step > 0 {
                    Button(String(localized: "上一步")) { step -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "为 macOS 而设计")).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                Spacer()
                if step == 2 {
                    Button(String(localized: "跳过")) { step = 3 }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
                }
                Button(step == 0 ? String(localized: "开始设置") : step < 3 ? String(localized: "下一步") : String(localized: "开始使用")) {
                    if step < 3 { step += 1 } else { model.finishSetup() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(step == 1 && !permissionsReady)
            }
            .padding(.horizontal, 36).padding(.vertical, 20)
            .background(Theme.cardBackground)
        }
        .background(Theme.settingsBackground)
        // Only the permission pages re-check on a timer, and only while they are visible.
        .task(id: step) {
            guard step == 1 || step == 2 else { return }
            while !Task.isCancelled {
                model.refreshInputSourceStatus()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func progressAccessibilityValue(for index: Int) -> String {
        if index < step { return String(localized: "已完成") }
        if index == step { return String(localized: "当前步骤") }
        return String(localized: "未开始")
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text(String(localized: "说出来，就写好了。"))
                    .font(.system(size: 30, weight: .semibold))
                Text(String(localized: "语音输入、拼音打字，还有随手可用的翻译。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 7) {
                    Image(systemName: "mic").foregroundStyle(Theme.accent)
                    Text(String(localized: "你说")).foregroundStyle(.secondary)
                }.font(.system(size: 12))
                Text(String(localized: "我们明天下午三点见。"))
                    .font(.system(size: 20, weight: .medium))
                Divider().opacity(0.5)
                Text("See you tomorrow at 3 PM.")
                    .font(.system(size: 20, weight: .medium))
                HStack {
                    Text(String(localized: "也可以直接写下原话")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Keycap(text: model.prefs.pushToTalk.shortLabel)
                    Text(model.prefs.tapToTalk ? String(localized: "点按说话") : String(localized: "按住说话")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 28) {
                Label(String(localized: "语音输入"), systemImage: "mic")
                Label(String(localized: "拼音打字"), systemImage: "keyboard")
                Label(String(localized: "划区翻译"), systemImage: "text.viewfinder")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(spacing: 22) {
            VStack(spacing: 9) {
                Text(String(localized: "只差两步，就能开口输入"))
                    .font(.system(size: 26, weight: .semibold))
                Text(String(localized: "一次开一项。开启后会自动更新状态，回到这里继续即可。"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            PermissionsSettingsView(requiredOnly: true, sequential: true)
        }
    }

    private var optional: some View {
        VStack(spacing: 22) {
            VStack(spacing: 9) {
                Text(String(localized: "可选，但很好用"))
                    .font(.system(size: 26, weight: .semibold))
                Text(String(localized: "这些权限让 Saylane 在其它输入法和更多应用里也能用。都可以跳过。"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            PermissionsSettingsView(optionalOnly: true)
        }
    }

    private var trial: some View {
        VStack(spacing: 22) {
            VStack(spacing: 9) {
                Text(String(localized: "现在，说一句试试"))
                    .font(.system(size: 26, weight: .semibold))
                Text(model.prefs.tapToTalk
                     ? String(localized: "点按 \(model.prefs.pushToTalk.shortLabel)，说完按任意键提交。")
                     : String(localized: "按住 \(model.prefs.pushToTalk.shortLabel)，说完松开即可。"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            DictationTrialView()
            if let conflict = ShortcutValidator.appleDictationConflict(for: model.prefs.pushToTalk) {
                Label(conflict, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            if !model.ready {
                HStack(spacing: 12) {
                    Text(model.readinessState.blocker?.message ?? String(localized: "正在检查模型…"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(recoveryTab == 2 ? String(localized: "准备模型") : String(localized: "检查权限")) { model.deferSetup(destination: recoveryTab) }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var recoveryTab: Int {
        switch model.readinessState.blocker {
        case .modelsChecking, .modelsMissing: return 2
        default: return 0
        }
    }
}

/// The trial field plus a live microphone meter, so the user sees the input
/// level before saying anything (Typeless' "blue bar").
struct DictationTrialView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var meter = MicrophoneLevelMeter()

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
                    .frame(height: 140)
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
