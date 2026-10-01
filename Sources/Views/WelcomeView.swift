import SwiftUI

/// First run, on one page. The input method is added and made current from
/// here; the talk key can be tried at once; what the system must be asked for
/// is asked where it is needed. Nobody is sent to System Settings for anything
/// that can be done in place.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SaylaneBrand()
                Spacer()
            }
            .padding(.horizontal, 36).padding(.top, 24)

            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 9) {
                        Text(String(localized: "说出来，就写好了。"))
                            .font(.system(size: 30, weight: .semibold))
                        Text(model.prefs.tapToTalk
                             ? String(localized: "点按 \(model.prefs.pushToTalk.shortLabel)，说完按任意键提交。")
                             : String(localized: "按住 \(model.prefs.pushToTalk.shortLabel)，说完松开即可。"))
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    if let notice = model.notice, notice.level == .actionable {
                        Text(notice.message).font(.system(size: 12)).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    DictationTrialView(height: 88)
                    if let conflict = ShortcutValidator.appleDictationConflict(for: model.prefs.pushToTalk) {
                        Label(conflict, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    if modelsPending {
                        HStack(spacing: 12) {
                            Text(model.readinessState.blocker?.message ?? String(localized: "正在检查模型…"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "准备模型")) { model.deferSetup(destination: 2) }.buttonStyle(.bordered)
                        }
                    }
                    PermissionsSettingsView(welcome: true)
                }
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .padding(.horizontal, 36).padding(.bottom, 24)
            }

            HStack {
                Text(String(localized: "为 macOS 而设计")).font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                Button(String(localized: "开始使用")) { model.finishSetup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .selfTestAnchor("welcome-done")
            }
            .padding(.horizontal, 36).padding(.vertical, 20)
            .background(Theme.cardBackground)
        }
        .background(Theme.settingsBackground)
        .selfTestAnchor("welcome")
        .task {
            // Saylane is put in the input-source list and made the current
            // input method here, before the user is asked to talk.
            model.ensureInputSource()
            // The system's own prompts and panes change things behind this
            // window: follow them while it is open.
            while !Task.isCancelled {
                model.refreshInputSourceStatus()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var modelsPending: Bool {
        switch model.readinessState.blocker {
        case .modelsChecking, .modelsMissing: return true
        default: return false
        }
    }
}
