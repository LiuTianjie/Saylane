import SwiftUI

/// Presentation state stays separate from the persisted permission readiness flag.
/// Becoming ready must not dismiss the guide while the user is reading it.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Int

    init(initialStep: Int = 0) {
        _step = State(initialValue: initialStep)
    }
    private let titles = ["欢迎使用", "开启权限", "试一下"]
    private var permissionsReady: Bool {
        SetupFlow.isComplete(installationPathValid: model.installationPathValid,
                             inputMethodEnabled: model.inputSourceEnabled,
                             microphoneGranted: model.permissions.microphone == .granted)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SaylaneBrand()
                Spacer()
                Button("稍后设置") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36).padding(.top, 24)

            HStack(spacing: 16) {
                ForEach(0..<3) { index in
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
                    if index != 2 { Rectangle().fill(Theme.hairlineStrong).frame(width: 42, height: 1) }
                }
            }
            .padding(.top, 30).padding(.bottom, 24)
            ScrollView {
                VStack(spacing: 22) {
                    if let error = model.lastError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if step == 0 { welcome }
                    else if step == 1 { permissions }
                    else { trial }
                }
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .padding(.horizontal, 36).padding(.bottom, 24)
            }
            HStack {
                if step > 0 {
                    Button("上一步") { step -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Text("为 macOS 而设计").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(step == 0 ? "开始设置" : step == 1 ? "下一步" : "开始使用") {
                    if step < 2 { step += 1 } else { finish() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(step == 1 && !permissionsReady)
            }
            .padding(.horizontal, 36).padding(.vertical, 20)
            .background(Theme.cardBackground)
        }
        .background(Theme.settingsBackground)
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("说出来，就写好了。")
                    .font(.system(size: 30, weight: .semibold))
                Text("语音输入、拼音打字，还有随手可用的翻译。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 7) {
                    Image(systemName: "mic").foregroundStyle(Theme.accent)
                    Text("你说").foregroundStyle(.secondary)
                }.font(.system(size: 12))
                Text("我们明天下午三点见。")
                    .font(.system(size: 20, weight: .medium))
                Divider().opacity(0.5)
                Text("See you tomorrow at 3 PM.")
                    .font(.system(size: 20, weight: .medium))
                HStack {
                    Text("也可以直接写下原话").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Keycap(text: model.pushToTalk.shortLabel)
                    Text(model.tapToTalk ? "点按说话" : "按住说话").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 28) {
                Label("语音输入", systemImage: "mic")
                Label("拼音打字", systemImage: "keyboard")
                Label("划区翻译", systemImage: "text.viewfinder")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(spacing: 22) {
            VStack(spacing: 9) {
                Text("只差两步，就能开口输入")
                    .font(.system(size: 26, weight: .semibold))
                Text("开启后会自动更新状态，回到这里继续即可。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            PermissionsSettingsView(requiredOnly: true)
            Text("截屏翻译等可选权限，可以稍后在「权限管理」中开启。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var trial: some View {
        VStack(spacing: 22) {
            VStack(spacing: 9) {
                Text("现在，说一句试试")
                    .font(.system(size: 26, weight: .semibold))
                Text("\(model.tapToTalk ? "点按" : "按住") \(model.pushToTalk.shortLabel)，说完\(model.tapToTalk ? "按任意键提交" : "松开即可")。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            DictationTrialView()
            if !model.ready {
                HStack(spacing: 12) {
                    Text(model.readiness.blocker?.message ?? "正在检查模型…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(recoveryTab == 2 ? "准备模型" : "检查权限") { finish(destination: recoveryTab) }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var recoveryTab: Int {
        switch model.readiness.blocker {
        case .modelsChecking, .modelsMissing: return 2
        default: return 0
        }
    }

    private func finish(destination: Int = 1) {
        model.settingsTab = destination
        model.coordinator.cancel()
        model.isShowingSetup = false
    }
}

struct DictationTrialView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: model.isListening ? "waveform" : "text.cursor")
                    .foregroundStyle(Theme.accent)
                Text(model.isListening ? "正在听你说…" : "语音试用区")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(model.currentDirection.compactTitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if model.testText.isEmpty {
                    Text("点这里，说说你今天的计划…")
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $model.testText)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .frame(height: 140)
                    .accessibilityLabel("听写测试输入框")
                    .allowsHitTesting(!model.isListening)
            }
            .font(.system(size: 17))
            Divider().opacity(0.5)
            HStack {
                Keycap(text: model.pushToTalk.shortLabel, compact: true)
                Text(model.isListening ? "正在识别…" : model.tapToTalk ? "点按开始，再按任意键提交" : "按住说话，松开提交")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { model.testText = "" }.buttonStyle(.plain)
                    .foregroundStyle(.secondary).disabled(model.isListening || model.testText.isEmpty)
            }
        }
        .padding(22)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.hairline))
    }
}
