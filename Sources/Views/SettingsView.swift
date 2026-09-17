import SwiftUI
import Translation

/// Settings follow the System Settings idiom: a plain sidebar, grouped forms, one accent
/// colour and one short footer per group. Details live in tooltips, not in the layout.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var testFocused: Bool
    @AppStorage("screenFontWeightExperiment") private var fontWeightExperiment = true
    @State private var deletingSpeechModel: SpeechModel?

    private struct Tab: Identifiable, Hashable {
        let id: Int
        let title: String
        let symbol: String
        let color: Color
    }
    private static let tabs: [Tab] = [
        Tab(id: 1, title: "语音输入", symbol: "mic.fill", color: .blue),
        Tab(id: 4, title: "截屏翻译", symbol: "text.viewfinder", color: .indigo),
        Tab(id: 3, title: "AI 修正", symbol: "wand.and.stars", color: .purple),
        Tab(id: 2, title: "本地模型", symbol: "cpu", color: .gray),
        Tab(id: 0, title: "开始使用", symbol: "checkmark.circle.fill", color: .green),
    ]
    private var currentTab: Tab { Self.tabs.first { $0.id == model.settingsTab } ?? Self.tabs[0] }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 ?? 1 })) {
                ForEach(Self.tabs) { tab in
                    Label { Text(tab.title) } icon: { SettingsGlyph(symbol: tab.symbol, color: tab.color) }
                        .tag(tab.id)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 176, ideal: 188, max: 220)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Form {
                if let error = model.lastError { errorBanner(error) }
                switch model.settingsTab {
                case 1: voice
                case 2: models
                case 3: FinalPolishSettingsView()
                case 4: screen
                default: setup
                }
            }
            .formStyle(.grouped)
            .navigationTitle(currentTab.title)
            .frame(maxWidth: 640)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
        .tint(.accentColor)
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
        VStack(alignment: .leading, spacing: 4) {
            StatusText(text: model.ready ? "已就绪" : "待完成设置", ready: model.ready)
            Text("Saylane \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func errorBanner(_ error: String) -> some View {
        Section {
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
        Section {
            Picker("我说", selection: $model.pairSource) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("写成", selection: $model.pairTarget) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("当前", selection: Binding(get: { model.currentDirection }, set: { model.setVoiceMode($0) })) {
                ForEach(modes) { Text($0.compactTitle).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("语言")
        } footer: {
            Text("双击右 ⌘ 在这四种组合之间轮转。")
        }
        .disabled(busy)

        Section {
            Picker("触发", selection: $model.tapToTalk) {
                Text("按住说话").tag(false)
                Text("点按开始").tag(true)
            }
            Picker("快捷键", selection: $model.pushToTalk) {
                ForEach(PushToTalkHotkey.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("双击右 ⌘ 切换方向", isOn: $model.languageSwitchEnabled)
            Toggle("说话时显示底部声波", isOn: $model.overlayEnabled)
        } header: {
            Text("说话")
        } footer: {
            Text(model.tapToTalk ? "点一下开始录音，再按任意键提交。" : "按住说话，松开提交；和其他键一起按不会触发。")
        }
        .disabled(model.isListening)

        Section {
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
            Text("Rime 拼音：空格上屏、数字改词、Shift 切中英；中文模式可直接出英文单词。")
        }
        .disabled(model.isListening)
    }

    // MARK: - 截屏翻译

    @ViewBuilder private var screen: some View {
        @Bindable var model = model
        Section {
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

        Section {
            Toggle("本地字重识别", isOn: $fontWeightExperiment)
                .help("实验功能：按原图字形判断粗细，可能漏识别小字号粗体；更改后下次划选生效")
            LabeledContent("大模型润色") {
                Text(model.screenPolishEnabled ? "已开启" : "未开启").foregroundStyle(.secondary)
            }
        } header: {
            Text("译文")
        } footer: {
            Text("大模型润色在「AI 修正」中统一设置。截图不会上传。")
        }

        Section {
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

    // MARK: - 开始使用

    @ViewBuilder private var setup: some View {
        @Bindable var model = model
        Section {
            if let blocker = model.readiness.blocker {
                Label(blocker.message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12.5))
            }
            checkRow("麦克风", detail: model.permissions.microphone == .granted ? "仅听写时采集" : model.permissions.microphone == .denied ? "在系统里被拒绝了" : "还没授权", ready: model.permissions.microphone == .granted) {
                Button(model.permissions.isRequestingMicrophone ? "等待授权…" : model.permissions.microphone == .denied ? "前往授权" : "允许") {
                    Task { await model.requestMicrophonePermission() }
                }.disabled(model.permissions.isRequestingMicrophone)
            }
            checkRow("输入法", detail: model.inputSourceSelected ? "已选中 Saylane" : model.inputSourceEnabled ? "已启用，按快捷键会自动选中" : model.inputSourceInstalled ? "已安装，尚未启用" : "系统还没发现组件", ready: model.inputSourceEnabled) {
                Button(model.isActivatingInputSource ? "等待启用…" : model.inputSourceEnabled ? "选中" : "启用") { model.enableInputSource() }
                    .disabled(model.isActivatingInputSource || !model.installationPathValid)
            }
            checkRow("模型", detail: model.speechModelReady && model.translationModelReady ? "当前语言已就绪" : "按所选语言下载", ready: model.speechModelReady && model.translationModelReady) {
                Button("去下载") { model.settingsTab = 2 }
            }
            checkRow("全局唤醒", detail: model.globalHotkeyActive ? "其它输入法下也能按快捷键说话" : model.permissions.inputMonitoringGranted ? "权限有了，监听还没接上" : "需要输入监控权限", ready: model.globalHotkeyActive) {
                Button(model.permissions.inputMonitoringGranted ? "重新接入" : "允许") { model.requestInputMonitoring() }
            }
        } header: {
            Text("准备")
        } footer: {
            HStack {
                if !model.installationPathValid {
                    Text("这是未安装的构建副本，请用安装包装到系统输入法目录。").foregroundStyle(.orange)
                }
                Spacer()
                Button("打开系统输入法设置") { InputSourceInstall.openSystemInputSourceSettings() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }

        Section {
            TextEditor(text: $model.testText)
                .focused($testFocused)
                .font(.system(size: 16, design: .rounded))
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("听写测试输入框")
            HStack {
                Button {
                    if model.ready { testFocused = true }
                    else if model.permissions.microphone == .denied {
                        Task { await model.requestMicrophonePermission() }
                    } else { model.beginSetup() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isSetupRunning { ProgressView().controlSize(.small) }
                        Text(model.isSetupRunning ? "正在完成…" : model.ready ? "试说一句" : model.permissions.microphone == .denied ? "去允许麦克风" : "继续设置")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSetupRunning || model.permissions.isRequestingMicrophone)
                Spacer()
                Button("清空") { model.coordinator.cancel(); model.testText = "" }.buttonStyle(.link)
            }
        } header: {
            Text("试一下")
        } footer: {
            Text(model.completedSessions > 0
                 ? "点进输入框，按住 \(model.pushToTalk.shortLabel) 说一句。已提交 \(model.completedSessions) 次。"
                 : "点进输入框，按住 \(model.pushToTalk.shortLabel) 说一句；当前是\(model.currentDirection.title)。")
        }
    }

    private func checkRow<Action: View>(_ title: String, detail: String, ready: Bool, @ViewBuilder action: () -> Action) -> some View {
        LabeledContent {
            if ready {
                StatusText(text: detail, ready: true)
            } else {
                HStack(spacing: 10) {
                    Text(detail).foregroundStyle(.secondary).font(.system(size: 12))
                    action().controlSize(.small)
                }
            }
        } label: {
            Text(title)
        }
    }

    // MARK: - 本地模型

    @ViewBuilder private var models: some View {
        @Bindable var model = model
        Section {
            LabeledContent("语音") { StatusText(text: model.speechModelDetail, ready: model.speechModelReady) }
            LabeledContent("翻译") { StatusText(text: model.translationModelDetail, ready: model.translationModelReady) }
        } header: {
            Text("状态")
        }

        Section {
            ForEach(SpeechModel.allCases) { speechModelRow($0) }
        } header: {
            Text("识别模型")
        } footer: {
            Text("权重按需下载，可分别删除。SenseVoice 边说边刷新预览，Fun-ASR-Nano 与 Qwen 松开后出字；每次最多 30 秒。")
        }

        Section {
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
