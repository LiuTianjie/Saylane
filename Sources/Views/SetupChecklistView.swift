import SwiftUI

/// The four things Saylane needs from the Mac, each with its state and the one
/// control that settles it. The guide and the Permissions page show the same
/// list; the guide also points at the item that is next.
struct SetupChecklistView: View {
    @Environment(AppModel.self) private var model
    /// In the guide the next open item is marked and the others wait their turn.
    var guide = false
    /// Items whose control was used: they say what to do in the pane that opened.
    @State private var asked: Set<SetupStep> = []

    var body: some View {
        let list = model.setupChecklist
        if guide, list.isComplete, model.router.isGlobalTapFiltering || model.testChecklist != nil {
            // Nothing left to do: the list steps aside for the trial field.
            HStack(spacing: 0) {
                ForEach(SetupStep.allCases, id: \.rawValue) { step in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                        Text(title(step)).font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .selfTestAnchor("setup-row-\(step.rawValue)")
                }
            }
            .padding(.vertical, 14)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline.opacity(0.55)))
            .accessibilityElement(children: .combine)
        } else {
            rows(list)
        }
    }

    private func rows(_ list: SetupChecklist) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.readinessState.inputSource.installedLocation {
                Label(String(localized: "这是未安装的构建副本，请先用安装包安装。"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.system(size: 12.5))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                Divider().opacity(0.45)
            }
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                row(step, list: list)
                if step != SetupStep.allCases.last { Divider().opacity(0.45).padding(.leading, 56) }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline.opacity(0.55)))
        .animation(.easeOut(duration: 0.2), value: list)
    }

    private func row(_ step: SetupStep, list: SetupChecklist) -> some View {
        let done = list.isDone(step)
        let current = guide && list.next == step
        return HStack(alignment: .center, spacing: 14) {
            StepBadge(number: step.rawValue + 1, done: done, current: current)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: symbol(step)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(title(step)).font(.system(size: 14, weight: .medium))
                }
                Text(detail(step, done: done))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if done {
                if step == .accessibility, !model.router.isGlobalTapFiltering {
                    // Allowed, but the listener is not attached yet: one click attaches it.
                    Button(String(localized: "重新接入")) { model.reconnectGlobalKeys() }.controlSize(.small)
                } else {
                    Text(String(localized: "已开启"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    asked.insert(step)
                    model.perform(step)
                } label: {
                    HStack(spacing: 6) {
                        if busy(step) { ProgressView().controlSize(.small) }
                        Text(actionTitle(step))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy(step))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(current ? Theme.accent.opacity(0.06) : .clear)
        .selfTestAnchor("setup-row-\(step.rawValue)")
        .accessibilityElement(children: .combine)
    }

    private func busy(_ step: SetupStep) -> Bool {
        switch step {
        case .inputMethod: return model.isActivatingInputSource
        case .microphone: return model.permissions.isRequestingMicrophone
        case .accessibility, .screenRecording: return false
        }
    }

    private func symbol(_ step: SetupStep) -> String {
        switch step {
        case .inputMethod: return "keyboard"
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed"
        }
    }

    private func title(_ step: SetupStep) -> String {
        switch step {
        case .inputMethod: return String(localized: "输入法")
        case .microphone: return String(localized: "麦克风")
        case .accessibility: return String(localized: "辅助功能")
        case .screenRecording: return String(localized: "屏幕录制")
        }
    }

    private func actionTitle(_ step: SetupStep) -> String {
        switch step {
        case .inputMethod:
            if model.isActivatingInputSource { return String(localized: "正在添加…") }
            return model.readinessState.inputSource.enabled ? String(localized: "切换到 Saylane") : String(localized: "添加")
        case .microphone:
            if model.permissions.isRequestingMicrophone { return String(localized: "等待授权…") }
            return model.permissions.microphone == .denied ? String(localized: "打开系统设置") : String(localized: "允许")
        case .accessibility: return String(localized: "打开系统设置")
        case .screenRecording: return asked.contains(.screenRecording) ? String(localized: "打开系统设置") : String(localized: "允许")
        }
    }

    private func detail(_ step: SetupStep, done: Bool) -> String {
        switch step {
        case .inputMethod:
            let source = model.readinessState.inputSource
            if done {
                return source.selected ? String(localized: "已加入输入法，现在用的就是 Saylane")
                                       : String(localized: "已加入输入法；在别的输入法下也能按键说话")
            }
            if model.isActivatingInputSource { return String(localized: "正在加入输入法列表…") }
            if source.enabled { return String(localized: "已加入；现在用的是别的输入法，切到 Saylane 才能打字和说话") }
            if !source.installedLocation { return String(localized: "请先用安装包安装") }
            return String(localized: "把 Saylane 加入输入法并切换过去，不用去系统设置")
        case .microphone:
            if done { return String(localized: "只在你按住说话时录音") }
            return model.permissions.microphone == .denied
                ? String(localized: "之前被拒绝了：在系统设置的“麦克风”里打开 Saylane")
                : String(localized: "按住说话时录音；不说话不采集")
        case .accessibility:
            if done {
                return model.router.isGlobalTapFiltering ? String(localized: "任何应用、任何输入法下都能按键说话")
                                                         : String(localized: "已允许；按键监听还没有接上")
            }
            if asked.contains(.accessibility) { return String(localized: "在打开的列表里把 Saylane 的开关打开，这里会自己变成已开启") }
            return model.prefs.pushToTalk.isModifier
                ? String(localized: "让说话键在任何应用里都能用，并把文字直接写到光标处")
                : String(localized: "当前的说话键是功能键，必须开启这一项才能用")
        case .screenRecording:
            if done { return String(localized: "所见即译只截你框出的那一块") }
            if asked.contains(.screenRecording) { return String(localized: "打开开关后系统会重新打开 Saylane，回来后从这里继续") }
            return String(localized: "所见即译要用；只截你框出的那一块，不上传")
        }
    }
}

/// A number while the item is open, a tick once it is on.
private struct StepBadge: View {
    let number: Int
    let done: Bool
    let current: Bool

    var body: some View {
        ZStack {
            Circle().fill(done ? Theme.ready : current ? Theme.accent : Color.clear)
            Circle().strokeBorder(done || current ? Color.clear : Theme.hairlineStrong, lineWidth: 1.5)
            if done {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
