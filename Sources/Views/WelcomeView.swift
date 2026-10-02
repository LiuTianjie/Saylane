import SwiftUI

/// The first run, on one page: everything Saylane needs from the Mac is turned
/// on here, once — the input method (added and switched to in place), the
/// microphone, Accessibility and Screen Recording — so that nothing is asked
/// for later, in the middle of a sentence or a capture. One button settles
/// whatever is next; the page follows the system's prompts and panes by itself.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.setupChecklist
        VStack(spacing: 0) {
            HStack {
                SaylaneBrand()
                Spacer()
            }
            .padding(.horizontal, 36).padding(.top, 24)

            ScrollView {
                VStack(spacing: 20) {
                    header(list)
                    if let notice = model.notice, notice.level == .actionable {
                        Text(notice.message).font(.system(size: 12)).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    SetupChecklistView(guide: true)
                    // With everything on, the page turns into a place to try it.
                    if list.isComplete {
                        DictationTrialView(height: 110)
                            .transition(.opacity)
                        if let conflict = ShortcutValidator.appleDictationConflict(for: model.prefs.pushToTalk) {
                            Label(conflict, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
                .padding(.horizontal, 36).padding(.top, 6).padding(.bottom, 24)
                .animation(.easeOut(duration: 0.2), value: list)
            }

            footer(list)
        }
        .background(Theme.settingsBackground)
        .selfTestAnchor("welcome")
        .task {
            // Saylane is put in the input-source list and made the current
            // input method here, before anything else is asked.
            model.ensureInputSource()
            // The system's own prompts and panes change things behind this
            // window: follow them while it is open.
            while !Task.isCancelled {
                model.refreshInputSourceStatus()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func header(_ list: SetupChecklist) -> some View {
        VStack(spacing: 10) {
            Text(list.isComplete ? String(localized: "都准备好了") : String(localized: "先把这四项打开"))
                .font(.system(size: 28, weight: .semibold))
            Text(list.isComplete
                 ? (model.prefs.tapToTalk ? String(localized: "点按 \(model.prefs.pushToTalk.shortLabel)，说完按任意键提交。")
                                          : String(localized: "按住 \(model.prefs.pushToTalk.shortLabel)，说完松开即可。"))
                 : String(localized: "只需要这一次。之后说话、打字和截屏翻译都不会再被权限打断。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fillStrong)
                        Capsule().fill(list.isComplete ? Theme.ready : Theme.accent)
                            .frame(width: geo.size.width * CGFloat(list.count) / CGFloat(SetupStep.allCases.count))
                    }
                }
                .frame(width: 180, height: 5)
                Text(String(localized: "已开启 \(list.count) / \(SetupStep.allCases.count)"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func footer(_ list: SetupChecklist) -> some View {
        HStack(spacing: 14) {
            if list.isComplete {
                Text(String(localized: "这些都可以在“设置 → 权限管理”里再看。")).font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                // Never a dead end: someone who will not grant an item can still get in.
                Button(String(localized: "稍后再说")) { model.deferSetup() }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                    .selfTestAnchor("welcome-later")
            }
            Spacer()
            Button {
                if list.isComplete { model.finishSetup() } else { model.performNextSetupStep() }
            } label: {
                Text(primaryTitle(list)).frame(minWidth: 132)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .selfTestAnchor("welcome-done")
        }
        .padding(.horizontal, 36).padding(.vertical, 18)
        .background(Theme.cardBackground)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
    }

    private func primaryTitle(_ list: SetupChecklist) -> String {
        switch list.next {
        case .inputMethod: return String(localized: "添加输入法")
        case .microphone: return String(localized: "允许麦克风")
        case .accessibility: return String(localized: "开启辅助功能")
        case .screenRecording: return String(localized: "允许屏幕录制")
        case nil: return String(localized: "开始使用")
        }
    }
}
