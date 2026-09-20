import SwiftUI
import Translation

/// A quiet sidebar and aligned setting rows, shared with the first-run experience.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("screenFontWeightExperiment") private var fontWeightExperiment = true
    @State private var deletingSpeechModel: SpeechModel?
    var initialSetupStep = 0

    private struct Tab: Identifiable, Hashable {
        let id: Int
        let title: String
        let symbol: String
    }
    private static let tabs: [Tab] = [
        Tab(id: 1, title: "语音输入", symbol: "mic"),
        Tab(id: 5, title: "键盘输入", symbol: "keyboard"),
        Tab(id: 4, title: "截屏翻译", symbol: "text.viewfinder"),
        Tab(id: 3, title: "文字修正", symbol: "wand.and.stars"),
        Tab(id: 2, title: "本地模型", symbol: "square.stack.3d.up"),
        Tab(id: 0, title: "权限管理", symbol: "lock"),
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
                                if let error = model.lastError { errorBanner(error) }
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
        .translationTask(model.translationConfiguration) { session in
            await model.handleTranslationSession(session)
        }
        .alert("删除已下载的语音模型？", isPresented: Binding(
            get: { deletingSpeechModel != nil },
            set: { if !$0 { deletingSpeechModel = nil } }
        )) {
            Button("取消", role: .cancel) { deletingSpeechModel = nil }
            Button("删除", role: .destructive) {
                if let selected = deletingSpeechModel {
                    Task { await model.removeSpeechModel(selected) }
                }
                deletingSpeechModel = nil
            }
        } message: {
            Text("只删除此版本的本地模型文件。若正在使用它，将切回 Apple；以后可以重新下载。")
        }
        .task {
            await model.refreshModelStatus()
            while !Task.isCancelled {
                model.refreshInputSourceStatus()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.beginSetup() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 15))
                        .accessibilityHidden(true)
                    Text(model.setupCompleted ? "使用引导" : "完成设置")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            }
            .buttonStyle(SettingsGuideButtonStyle())
            .accessibilityHint("打开 Saylane 的设置引导和语音试用")
            VStack(alignment: .leading, spacing: 8) {
                StatusText(text: model.ready ? "已就绪" : "待完成设置", ready: model.ready)
                Text("Saylane \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 12)
    }

    private func errorBanner(_ error: String) -> some View {
        SettingsSection {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.system(size: 12)).textSelection(.enabled)
                Spacer()
                Button { model.lastError = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("关闭提示")
            }
        }
    }

    // MARK: - 语音输入

    @ViewBuilder private var voice: some View {
        @Bindable var model = model
        let modes = TranslationDirection.voiceModes(a: model.pairSource, b: model.pairTarget)
        let busy = model.isListening || model.isPreparingModels
        SettingsSection {
            LabeledContent("我说") {
                Picker("我说", selection: $model.pairSource) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent("写成") {
                Picker("写成", selection: $model.pairTarget) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent("当前") {
                Picker("当前", selection: Binding(get: { model.currentDirection }, set: { model.setVoiceMode($0) })) {
                    ForEach(modes) { Text($0.compactTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } header: {
            Text("语言")
        } footer: {
            Text("双击右 ⌘ 在这四种组合之间轮转。")
        }
        .disabled(busy)

        SettingsSection {
            LabeledContent("触发") {
                Picker("触发", selection: $model.tapToTalk) {
                    Text("按住说话").tag(false)
                    Text("点按开始").tag(true)
                }
                .labelsHidden()
            }
            LabeledContent("快捷键") {
                Picker("快捷键", selection: $model.pushToTalk) {
                    ForEach(PushToTalkHotkey.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("双击右 ⌘ 切换方向", isOn: $model.languageSwitchEnabled)
            Toggle("说话时显示底部声波", isOn: $model.overlayEnabled)
        } header: {
            Text("说话")
        } footer: {
            Text(model.tapToTalk ? "点一下开始录音，再按任意键提交。" : "按住说话，松开提交；和其他键一起按不会触发。")
        }
        .disabled(model.isListening)

    }

    @ViewBuilder private var keyboard: some View {
        SettingsSection {
            LabeledContent("当前模式") {
                HStack(spacing: 10) {
                    Text(model.pinyinEnglishMode ? "英文键盘" : "拼音中文").foregroundStyle(.secondary)
                    Button(model.pinyinEnglishMode ? "切到拼音" : "切到英文") { model.togglePinyinEnglishMode() }
                        .controlSize(.small)
                }
            }
            Toggle("候选条显示拼音", isOn: Binding(get: { model.pinyinBarPreeditEnabled }, set: { model.setPinyinBarPreeditEnabled($0) }))
            Toggle("模糊音", isOn: Binding(get: { model.pinyinFuzzyEnabled }, set: { model.setPinyinFuzzyEnabled($0) }))
                .help("zh/z、an/ang 等，精确音节优先")
            RimeDictionaryUpdateView(model: model.pinyinDictionaryUpdates)
            if let error = model.pinyin.initializationError {
                Text("拼音引擎未就绪：\(error)").font(.system(size: 12)).foregroundStyle(.red)
            }
        } header: {
            Text("拼音")
        } footer: {
            Text("空格确认，数字选词，Shift 切换中英文。中文模式也能直接输入英文单词。")
        }
        .disabled(model.isListening)
    }

    // MARK: - 截屏翻译

    @ViewBuilder private var screen: some View {
        @Bindable var model = model
        SettingsSection {
            LabeledContent("划选") { Text("按住左 ⌃ 约 0.3 秒后拖动").foregroundStyle(.secondary) }
            LabeledContent("额外快捷键") {
                Button {
                    model.beginRecordScreenShortcut()
                } label: {
                    Text(model.isRecordingScreenShortcut ? "按下新快捷键…" : model.screenCaptureShortcut.displayName)
                        .frame(minWidth: 72)
                }
                .controlSize(.small)
                .help("点击后按下新的截屏快捷键；和按住左 ⌃ 同时可用")
            }
            LabeledContent("钉住后") { Text("点左 ⌃ 切换原文 / 译文").foregroundStyle(.secondary) }
        } header: {
            Text("操作")
        } footer: {
            Text("松开鼠标即翻译，松开 ⌃ 取消。划选或钉住时双击右 ⌘ 切换方向，不影响说话。")
        }

        SettingsSection {
            Toggle("本地字重识别", isOn: $fontWeightExperiment)
                .help("实验功能：按原图字形判断粗细，可能漏识别小字号粗体；更改后下次划选生效")
            LabeledContent("大模型润色") {
                Text(model.screenPolishEnabled ? "已开启" : "未开启").foregroundStyle(.secondary)
            }
        } header: {
            Text("译文")
        } footer: {
            Text("大模型润色在「文字修正」中统一设置。截图不会上传。")
        }

        SettingsSection {
            LabeledContent("屏幕录制") {
                if model.permissions.screenCaptureGranted {
                    StatusText(text: "已允许，只截你划出的区域", ready: true)
                } else {
                    Button("允许") { model.requestScreenCapturePermission() }.controlSize(.small)
                }
            }
        } header: {
            Text("权限")
        }
    }

    // MARK: - 权限

    @ViewBuilder private var setup: some View {
        PermissionsSettingsView()
        DictationTrialView()
    }

    // MARK: - 本地模型

    @ViewBuilder private var models: some View {
        @Bindable var model = model
        SettingsSection {
            LabeledContent("语音") { StatusText(text: model.speechModelDetail, ready: model.speechModelReady) }
            LabeledContent("翻译") { StatusText(text: model.translationModelDetail, ready: model.translationModelReady) }
        } header: {
            Text("状态")
        }

        SettingsSection {
            ForEach(SpeechModel.allCases) { speechModelRow($0) }
        } header: {
            Text("识别模型")
        } footer: {
            Text("权重按需下载，可分别删除。本地模型按住说话时刷新预览，松开后再出最终结果；每次最多 30 秒。")
        }

        SettingsSection {
            Toggle("仅识别，不翻译", isOn: $model.recognitionOnly)
                .disabled(model.isListening || model.isChecking || model.isPreparingModels)
                .help("口误修正、个人词库和大模型校对不受影响")
            LabeledContent("当前语言所需模型") {
                Button {
                    Task { await model.downloadModels() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isPreparingModels || model.isChecking { ProgressView().controlSize(.small) }
                        Text(model.isPreparingModels ? "正在准备…" : model.isChecking ? "正在检查…" : "下载")
                    }
                }
                .controlSize(.small)
                .disabled(model.isPreparingModels || model.isChecking || model.isListening || model.asrModels.isDownloading)
            }
        } footer: {
            Text("Apple 资产由系统管理；本地模型从 Hugging Face 下载固定版本并校验。")
        }
    }

    private func speechModelRow(_ selected: SpeechModel) -> some View {
        let active = model.speechModel == selected
        let installed = model.asrModels.installed.contains(selected)
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
                Button("取消") { model.asrModels.cancelDownload() }.controlSize(.small)
            } else if selected == .apple || installed {
                if active && model.speechModelReady {
                    Text("使用中").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(active ? "重试" : "使用") { model.selectSpeechModel(selected) }.controlSize(.small).disabled(busy)
                }
                if installed {
                    Menu {
                        Button("重新下载修复") { Task { await model.downloadSpeechModel(selected) } }
                        Button("删除模型…", role: .destructive) { deletingSpeechModel = selected }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(busy)
                }
            } else {
                Button("下载") { Task { await model.downloadSpeechModel(selected) } }.controlSize(.small).disabled(busy)
            }
        }
    }
}
