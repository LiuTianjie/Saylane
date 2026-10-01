import SwiftUI

/// A quiet sidebar and aligned setting rows, shared with the first-run experience.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var deletingSpeechModel: SpeechModel?
    var initialSetupStep = 0

    private struct Tab: Identifiable, Hashable {
        let id: Int
        let title: String
        let symbol: String
    }
    private static let tabs: [Tab] = [
        Tab(id: 1, title: String(localized: "语音输入"), symbol: "mic"),
        Tab(id: 5, title: String(localized: "键盘输入"), symbol: "keyboard"),
        Tab(id: 4, title: String(localized: "截屏翻译"), symbol: "text.viewfinder"),
        Tab(id: 3, title: String(localized: "文字修正"), symbol: "wand.and.stars"),
        Tab(id: 2, title: String(localized: "本地模型"), symbol: "square.stack.3d.up"),
        Tab(id: 0, title: String(localized: "权限管理"), symbol: "lock"),
    ]
    private var currentTab: Tab { Self.tabs.first { $0.id == model.settingsTab } ?? Self.tabs[0] }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isShowingSetup {
                OnboardingView(initialStep: initialSetupStep)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        SaylaneBrand().padding(.horizontal, 16).padding(.top, 27).padding(.bottom, 22)
                        ForEach(Self.tabs) { tab in
                            SettingsNavigationButton(title: tab.title, symbol: tab.symbol,
                                                     selected: model.settingsTab == tab.id) {
                                model.settingsTab = tab.id
                            }
                        }
                        Spacer(minLength: 24)
                        sidebarFooter
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 204)
                    .background(Theme.sidebarBackground)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(currentTab.title)
                            .font(.system(size: 18, weight: .semibold))
                            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                if let notice = model.notice { NoticeBanner(notice: notice) }
                                switch model.settingsTab {
                                case 0: setup
                                case 1: voice
                                case 2: models
                                case 3: FinalPolishSettingsView()
                                case 4: screen
                                case 5: keyboard
                                default: voice
                                }
                            }
                            .padding(.horizontal, 26).padding(.bottom, 28)
                            .frame(maxWidth: 760)
                            .frame(maxWidth: .infinity)
                        }
                        .id(model.settingsTab)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.settingsBackground)
                }
            }
        }
        .font(.system(size: 13))
        .toggleStyle(SettingsToggleStyle())
        .labeledContentStyle(SettingsLabeledContentStyle())
        .controlSize(.regular)
        .tint(Theme.accent)
        .frame(minWidth: 780, minHeight: 600)
        .alert(String(localized: "删除已下载的语音模型？"), isPresented: Binding(
            get: { deletingSpeechModel != nil },
            set: { if !$0 { deletingSpeechModel = nil } }
        )) {
            Button(String(localized: "取消"), role: .cancel) { deletingSpeechModel = nil }
            Button(String(localized: "删除"), role: .destructive) {
                if let selected = deletingSpeechModel {
                    Task { await model.removeSpeechModel(selected) }
                }
                deletingSpeechModel = nil
            }
        } message: {
            Text(String(localized: "只删除此版本的本地模型文件。若正在使用它，将切回 Apple；以后可以重新下载。"))
        }
        // Event driven, not polled: once on appear, again whenever the window becomes key.
        .task { model.refreshInputSourceStatus(); await model.refreshModelStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshInputSourceStatus()
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.beginSetup() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 15))
                        .accessibilityHidden(true)
                    Text(model.setupCompleted ? String(localized: "使用引导") : String(localized: "完成设置"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            }
            .buttonStyle(SettingsGuideButtonStyle())
            .accessibilityHint(String(localized: "打开 Saylane 的设置引导和语音试用"))
            VStack(alignment: .leading, spacing: 8) {
                StatusText(text: model.ready ? String(localized: "已就绪") : String(localized: "待完成设置"), ready: model.ready)
                Text("Saylane \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 12)
    }

    // MARK: - 语音输入

    @ViewBuilder private var voice: some View {
        let p = model.prefs
        let modes = TranslationDirection.voiceModes(a: p.pairSource, b: p.pairTarget)
        let busy = model.isListening || model.isPreparingModels
        let functionKeyNeedsFiltering = !p.pushToTalk.isModifier && !model.router.isGlobalTapFiltering
        SettingsSection {
            LabeledContent(String(localized: "我说")) {
                Picker(String(localized: "我说"), selection: Binding(get: { p.pairSource }, set: { model.setLanguagePair(a: $0, b: p.pairTarget) })) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent(String(localized: "写成")) {
                Picker(String(localized: "写成"), selection: Binding(get: { p.pairTarget }, set: { model.setLanguagePair(a: p.pairSource, b: $0) })) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent(String(localized: "当前")) {
                Picker(String(localized: "当前"), selection: Binding(get: { model.currentDirection }, set: { model.setVoiceMode($0) })) {
                    ForEach(modes) { Text($0.compactTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } header: {
            Text(String(localized: "语言"))
        } footer: {
            Text(String(localized: "双击右 ⌘ 在这四种组合之间轮转。"))
        }
        .disabled(busy)

        SettingsSection {
            LabeledContent(String(localized: "触发")) {
                Picker(String(localized: "触发"), selection: model.binding(\.tapToTalk)) {
                    Text(String(localized: "按住说话")).tag(false)
                    Text(String(localized: "点按开始")).tag(true)
                }
                .labelsHidden()
            }
            LabeledContent(String(localized: "快捷键")) {
                Picker(String(localized: "快捷键"), selection: model.binding(\.pushToTalk)) {
                    ForEach(PushToTalkHotkey.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            if let conflict = ShortcutValidator.appleDictationConflict(for: p.pushToTalk) {
                Label(conflict, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            if functionKeyNeedsFiltering {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label {
                        Text(model.readinessState.permissions.accessibility
                             ? String(localized: "全局按键拦截尚未接入，当前功能键无法可靠使用；请改用 Option、Command、Control、Shift 或 fn。")
                             : String(localized: "当前功能键需要辅助功能权限才能可靠使用；也可以改用 Option、Command、Control、Shift 或 fn。"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button(model.readinessState.permissions.accessibility
                           ? String(localized: "重新接入") : String(localized: "去开通")) {
                        if model.readinessState.permissions.accessibility {
                            model.requestInputMonitoring()
                        } else {
                            model.requestAccessibility()
                        }
                    }
                    .controlSize(.small)
                }
            }
            Toggle(String(localized: "双击右 ⌘ 切换方向"), isOn: model.binding(\.languageSwitchEnabled))
        } header: {
            Text(String(localized: "说话"))
        } footer: {
            Text(p.tapToTalk ? String(localized: "点一下开始录音，再按任意键提交。按下的那一刻就已经在录音，不会丢掉开头。")
                             : String(localized: "按住说话，松开提交；和其他键一起按不会触发。按下的那一刻就已经在录音，不会丢掉开头。"))
        }
        .disabled(model.isListening)

        SettingsSection {
            Toggle(String(localized: "说话时显示底部提示"), isOn: model.binding(\.overlayEnabled))
            Toggle(String(localized: "提示里显示识别和译文"), isOn: model.binding(\.overlayShowsText))
                .disabled(!p.overlayEnabled)
                .help(String(localized: "在不显示组字的应用（终端、部分网页）里也能看到识别结果。"))
            if !model.readinessState.permissions.accessibility {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(String(localized: "还没有允许辅助功能：在其它输入法下，或在不接受输入法写入的应用里，语音结果只能复制到剪贴板。"),
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button(String(localized: "去开通")) { model.requestAccessibility() }.controlSize(.small)
                }
            }
        } header: {
            Text(String(localized: "反馈与兼容"))
        }
        .disabled(model.isListening)
    }

    @ViewBuilder private var keyboard: some View {
        let p = model.prefs
        SettingsSection {
            LabeledContent(String(localized: "当前模式")) {
                HStack(spacing: 10) {
                    Text(p.pinyinEnglishMode ? String(localized: "英文键盘") : String(localized: "拼音中文")).foregroundStyle(.secondary)
                    Button(p.pinyinEnglishMode ? String(localized: "切到拼音") : String(localized: "切到英文")) { model.togglePinyinEnglishMode() }
                        .controlSize(.small)
                }
            }
            Toggle(String(localized: "候选条显示拼音"), isOn: model.binding(\.pinyinBarPreeditEnabled))
            Toggle(String(localized: "模糊音"), isOn: model.binding(\.pinyinFuzzyEnabled))
                .help(String(localized: "zh/z、an/ang 等，精确音节优先"))
            RimeDictionaryUpdateView(model: model.pinyinDictionaryUpdates)
            if let error = model.pinyin.initializationError {
                Text(String(localized: "拼音引擎未就绪：\(error)")).font(.system(size: 12)).foregroundStyle(.red)
            }
        } header: {
            Text(String(localized: "拼音"))
        } footer: {
            Text(String(localized: "空格确认，数字选词，Shift 切换中英文。每个窗口各自记住正在输入的拼音，切换窗口不会误提交。"))
        }
        .disabled(model.isListening)
    }

    // MARK: - 截屏翻译

    @ViewBuilder private var screen: some View {
        let p = model.prefs
        SettingsSection {
            LabeledContent(String(localized: "快捷键")) {
                ShortcutRecorderField()
            }
            Toggle(String(localized: "长按左 ⌃ 也能划选"), isOn: model.binding(\.screenHoldEnabled))
                .help(String(localized: "按住左 ⌃ 约 0.3 秒进入划选。终端用户常先按住 ⌃，默认关闭以免误触。"))
            LabeledContent(String(localized: "钉住后")) {
                Text(String(localized: "Tab 切换原文 / 译文，⌘C 复制，D 换方向，Esc 关闭；可拖动")).foregroundStyle(.secondary)
            }
            Toggle(String(localized: "钉住时冻结其他窗口"), isOn: model.binding(\.screenPinFreezesScreen))
                .help(String(localized: "开启后，钉住期间不能操作其他应用，直到关闭。"))
        } header: {
            Text(String(localized: "操作"))
        } footer: {
            Text(String(localized: "松开鼠标即翻译，Esc 取消。钉图浮在最上层，可以继续使用其他应用。"))
        }

        SettingsSection {
            Toggle(String(localized: "本地字重识别"), isOn: model.binding(\.screenFontWeightExperiment))
                .help(String(localized: "实验功能：按原图字形判断粗细，可能漏识别小字号粗体；更改后下次划选生效"))
            LabeledContent(String(localized: "大模型润色")) {
                Text(p.screenPolishEnabled ? String(localized: "已开启") : String(localized: "未开启")).foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "译文"))
        } footer: {
            Text(String(localized: "大模型润色在「文字修正」中统一设置。截图不会上传。"))
        }

        SettingsSection {
            LabeledContent(String(localized: "屏幕录制")) {
                if model.permissions.screenCaptureGranted {
                    StatusText(text: String(localized: "已允许，只截你划出的区域"), ready: true)
                } else {
                    Button(String(localized: "允许")) { model.requestScreenCapturePermission() }.controlSize(.small)
                }
            }
        } header: {
            Text(String(localized: "权限"))
        }
    }

    // MARK: - 权限

    @ViewBuilder private var setup: some View {
        PermissionsSettingsView()
        DictationTrialView()
    }

    // MARK: - 本地模型

    @ViewBuilder private var models: some View {
        let r = model.readinessState.models
        SettingsSection {
            LabeledContent(String(localized: "语音")) { StatusText(text: r.speechDetail, ready: r.speechReady) }
            LabeledContent(String(localized: "翻译")) { StatusText(text: r.translationDetail, ready: r.translationReady) }
        } header: {
            Text(String(localized: "状态"))
        }

        SettingsSection {
            ForEach(SpeechModel.allCases) { speechModelRow($0) }
        } header: {
            Text(String(localized: "识别模型"))
        } footer: {
            Text(String(localized: "权重按需下载，可分别删除。本地模型按住说话时刷新预览，松开后再出最终结果；每次最多 30 秒，超过时保留已识别的部分。"))
        }

        SettingsSection {
            Toggle(String(localized: "仅识别，不翻译"), isOn: model.binding(\.recognitionOnly))
                .disabled(model.isListening || model.isChecking || model.isPreparingModels)
                .help(String(localized: "口误修正、个人词库和大模型校对不受影响"))
            LabeledContent(String(localized: "当前语言所需模型")) {
                Button {
                    Task { await model.downloadModels() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isPreparingModels || model.isChecking { ProgressView().controlSize(.small) }
                        Text(model.isPreparingModels ? String(localized: "正在准备…") : model.isChecking ? String(localized: "正在检查…") : String(localized: "下载"))
                    }
                }
                .controlSize(.small)
                .disabled(model.isPreparingModels || model.isChecking || model.isListening || model.asrModels.isDownloading)
            }
        } footer: {
            Text(String(localized: "Apple 资产由系统管理；本地模型从 Hugging Face 下载固定版本并校验。翻译模型下载时会弹出一个小窗口，不需要打开设置。"))
        }
    }

    private func speechModelRow(_ selected: SpeechModel) -> some View {
        let active = model.prefs.speechModel == selected
        let installed = model.asrModels.installed.contains(selected)
        let stored = model.asrModels.stored.contains(selected)
        let downloading = model.asrModels.downloading == selected
        let busy = model.isListening || model.isChecking || model.isPreparingModels || model.asrModels.isDownloading
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.45))
            VStack(alignment: .leading, spacing: 2) {
                Text(selected.title)
                Text(selected.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if downloading {
                ProgressView(value: model.asrModels.progress).frame(width: 72)
                Button(String(localized: "取消")) { model.asrModels.cancelDownload() }.controlSize(.small)
            } else if selected == .apple || installed {
                if active && model.readinessState.models.speechReady {
                    Text(String(localized: "使用中")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(active ? String(localized: "重试") : String(localized: "使用")) { model.selectSpeechModel(selected) }.controlSize(.small).disabled(busy)
                }
                if installed {
                    Menu {
                        Button(String(localized: "重新下载修复")) { Task { await model.downloadSpeechModel(selected) } }
                        Button(String(localized: "删除模型…"), role: .destructive) { deletingSpeechModel = selected }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(busy)
                }
            } else {
                Button(String(localized: "下载")) { Task { await model.downloadSpeechModel(selected) } }.controlSize(.small).disabled(busy)
                if stored {
                    Menu {
                        Button(String(localized: "清理旧下载…"), role: .destructive) { deletingSpeechModel = selected }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(busy)
                }
            }
        }
    }
}

/// The settings-side presentation of `AppModel.notice`.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: UserNotice

    var body: some View {
        SettingsSection {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.level == .actionable ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(notice.level == .actionable ? .orange : .secondary)
                Text(notice.message).font(.system(size: 12)).textSelection(.enabled)
                Spacer()
                if notice.level == .actionable, notice.destination != .none, tab(for: notice.destination) != model.settingsTab {
                    Button(String(localized: "去处理")) { model.openSettings(for: notice.destination) }.controlSize(.small)
                }
                Button { model.dismissNotice() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel(String(localized: "关闭提示"))
            }
        }
    }

    private func tab(for destination: UserNotice.Destination) -> Int {
        switch destination {
        case .permissions: return 0
        case .models: return 2
        case .voice: return 1
        case .screen: return 4
        case .none: return -1
        }
    }
}

/// Click, press a chord, done. Rejections and warnings show inline.
struct ShortcutRecorderField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if model.isRecordingScreenShortcut { model.cancelRecordScreenShortcut() } else { model.beginRecordScreenShortcut() }
                } label: {
                    Text(model.isRecordingScreenShortcut ? String(localized: "按下新快捷键…") : model.prefs.screenCaptureShortcut.displayName)
                        .frame(minWidth: 88)
                }
                .controlSize(.small)
                .help(String(localized: "点击后按下新的截屏快捷键，Esc 取消"))
                if model.prefs.screenCaptureShortcut != .optionT {
                    Button(String(localized: "恢复默认")) { model.set(\.screenCaptureShortcut, .optionT) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            switch model.shortcutRecordingVerdict {
            case .rejected(let reason):
                Text(reason).font(.system(size: 11)).foregroundStyle(.red).multilineTextAlignment(.trailing)
            case .warning(let reason):
                Text(reason).font(.system(size: 11)).foregroundStyle(.orange).multilineTextAlignment(.trailing)
            default:
                EmptyView()
            }
        }
    }
}
