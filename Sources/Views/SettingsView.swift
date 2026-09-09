import SwiftUI
import Translation

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var testFocused: Bool
    @State private var deletingSpeechModel: SpeechModel?

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let error = model.lastError {
                            errorBanner(error)
                        }
                        switch model.settingsTab {
                        case 1: preferences
                        case 2: models
                        case 3: FinalPolishSettingsView()
                        default: onboarding
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.settingsBackground)
        }
        .frame(minWidth: 820, minHeight: 600)
        .tint(Theme.accent)
        .toggleStyle(.switch)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pageTitle)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .tracking(-0.4)
            Text(pageSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var pageTitle: String {
        switch model.settingsTab {
        case 1: return "语音输入"
        case 2: return "本地模型"
        case 3: return "AI 润色"
        default: return "开始使用"
        }
    }

    private var pageSubtitle: String {
        switch model.settingsTab {
        case 1: return "打字用拼音，说话用快捷键。两件事互不抢。"
        case 2: return "语音和翻译都在这台电脑上跑。"
        case 3: return "说完再润色一次，可选。"
        default: return "授权、启用、试一句。做完就能用。"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Saylane")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                navigationItem("语音输入", icon: "mic.fill", tab: 1)
                navigationItem("AI 润色", icon: "wand.and.stars", tab: 3)
                navigationItem("本地模型", icon: "cpu", tab: 2)
                navigationItem("开始使用", icon: "flag.fill", tab: 0)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.ready ? Theme.ready : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(model.ready ? "已就绪" : "待完成")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(model.pinyinEnglishMode ? "英文键盘" : "拼音选词")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
        }
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBackground)
    }

    private func navigationItem(_ title: String, icon: String, tab: Int) -> some View {
        let selected = model.settingsTab == tab
        return Button { model.settingsTab = tab } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Theme.accent.opacity(0.12) : .clear, in: Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.system(size: 12)).textSelection(.enabled)
            Spacer()
            Button { model.lastError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("关闭提示")
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Preferences (Voice Input Tab)
    private var preferences: some View {
        @Bindable var model = model
        let modes = TranslationDirection.voiceModes(a: model.pairSource, b: model.pairTarget)
        
        return VStack(alignment: .leading, spacing: 20) {
            // 优化原先红框部分：去掉原先两个巨大空荡荡的方块和突兀等号，采用干净清爽的语言选择卡片
            VStack(spacing: 12) {
                // 语言组合栏
                HStack(spacing: 0) {
                    // 我说
                    Menu {
                        ForEach(AppLanguage.allCases) { lang in
                            Button(lang.displayName) { model.pairSource = lang }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("说")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(model.pairSource.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // 互换按钮
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let temp = model.pairSource
                            model.pairSource = model.pairTarget
                            model.pairTarget = temp
                        }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(Theme.fill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("点击对调双语语种")
                    .padding(.horizontal, 10)

                    // 写成
                    Menu {
                        ForEach(AppLanguage.allCases) { lang in
                            Button(lang.displayName) { model.pairTarget = lang }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("写")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(model.pairTarget.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                // 快捷模式切换栏（保留原本的模式选择，样式微调为更柔和的 macOS 原生分段胶囊）
                HStack(spacing: 3) {
                    ForEach(modes) { mode in
                        let on = model.currentDirection == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { model.setVoiceMode(mode) }
                        } label: {
                            Text(mode.compactTitle)
                                .font(.system(size: 12, weight: on ? .semibold : .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background {
                                    if on {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.primary)
                                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                                    }
                                }
                                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Theme.fillStrong, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(16)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .disabled(model.isListening || model.isPreparingModels)

            // 原原本本的“说话”卡片，优化微调内部排版间距
            SettingsSection(title: "说话") {
                HStack(spacing: 12) {
                    HStack(spacing: 0) {
                        segment("按住", on: !model.tapToTalk) { model.tapToTalk = false }
                        segment("点按", on: model.tapToTalk) { model.tapToTalk = true }
                    }
                    .padding(3)
                    .background(Theme.fill, in: Capsule(style: .continuous))
                    .disabled(model.isListening)

                    Spacer(minLength: 8)

                    Picker("快捷键", selection: $model.pushToTalk) {
                        ForEach(PushToTalkHotkey.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 176)
                    .disabled(model.isListening)
                }
                Text(model.tapToTalk ? (model.pushToTalk == .rightCommand && model.languageSwitchEnabled
                    ? "单击后稍候开始，双击切换语言；录音中再按任意键提交。"
                    : "点一下开始，再按任意键提交。") : "按住说话，松开提交。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Divider().opacity(0.35)

                toggleRow("双击右 ⌘ 换方向", "在两个语言的听写和互译之间轮转", $model.languageSwitchEnabled)
                    .disabled(model.isListening || model.isPreparingModels)
                
                Divider().opacity(0.35)
                
                toggleRow("底部声波", "说话时出现，成功后扫光收起", $model.overlayEnabled)
            }

            // 原原本本的“键盘”卡片
            SettingsSection(title: "键盘") {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.pinyinEnglishMode ? "英文键盘" : "拼音中文")
                            .font(.system(size: 14, weight: .medium))
                        Text("Rime 拼音 · 空格上屏 · 数字改词 · Shift 中英")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.pinyinEnglishMode ? "拼音" : "英文") {
                        model.togglePinyinEnglishMode()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isListening)
                }

                Divider().opacity(0.35)

                if let error = model.pinyin.initializationError {
                    Text("拼音引擎未就绪：\(error)")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                RimeDictionaryUpdateView(model: model.pinyinDictionaryUpdates)

                Divider().opacity(0.35)

                Text("整句组词与选词学习由 Rime 提供；中文模式可出英文单词。词后联想暂不支持。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Divider().opacity(0.35)

                toggleRow("候选条显示拼音", "在候选词左侧展示 ni'hao，默认关闭", Binding(
                    get: { model.pinyinBarPreeditEnabled },
                    set: { model.setPinyinBarPreeditEnabled($0) }
                ))
                .disabled(model.isListening)

                Divider().opacity(0.35)

                toggleRow("模糊音", "zh/z、an/ang 等，精确音节优先", Binding(
                    get: { model.pinyinFuzzyEnabled },
                    set: { model.setPinyinFuzzyEnabled($0) }
                ))
                .disabled(model.isListening)
            }
        }
    }

    // MARK: - Onboarding View
    private var onboarding: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 22) {
            if let blocker = model.readiness.blocker {
                Label(blocker.message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 12) {
                Button {
                    if model.ready { testFocused = true }
                    else if model.permissions.microphone == .denied {
                        Task { await model.requestMicrophonePermission() }
                    } else { model.beginSetup() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isSetupRunning { ProgressView().controlSize(.small) }
                        Text(model.isSetupRunning ? "正在完成…" : model.ready ? "试说一句" : model.permissions.microphone == .denied ? "去允许麦克风" : "继续设置")
                    }
                    .frame(minWidth: 108)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSetupRunning || model.permissions.isRequestingMicrophone)
                if !model.setupCompleted {
                    Text("还没成功提交过一次")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: "准备") {
                checkRow("1", title: "麦克风", detail: model.permissions.microphone == .granted ? "仅听写时采集" : model.permissions.microphone == .denied ? "系统里被拒绝了" : "还没授权", ready: model.permissions.microphone == .granted) {
                    Button(model.permissions.isRequestingMicrophone ? "等待授权…" : model.permissions.microphone == .denied ? "前往授权" : "允许") {
                        Task { await model.requestMicrophonePermission() }
                    }.disabled(model.permissions.isRequestingMicrophone)
                }
                Divider().opacity(0.4)
                checkRow("2", title: "输入法", detail: model.inputSourceSelected ? "已选中 Saylane" : model.inputSourceEnabled ? "已启用，按快捷键会自动选中" : model.inputSourceInstalled ? "已安装，尚未启用" : "系统还没发现组件", ready: model.inputSourceEnabled) {
                    Button(model.isActivatingInputSource ? "等待启用…" : model.inputSourceEnabled ? "选中" : "启用") { model.enableInputSource() }
                        .disabled(model.isActivatingInputSource || !model.installationPathValid)
                }
                Divider().opacity(0.4)
                checkRow("3", title: "模型", detail: model.speechModelReady && model.translationModelReady ? "当前语言已就绪" : "按所选语言下载，录音时不会现下", ready: model.speechModelReady && model.translationModelReady) {
                    Button("去下载") { model.settingsTab = 2 }
                }
                Divider().opacity(0.4)
                checkRow("4", title: "全局唤醒", detail: model.globalHotkeyActive ? "其它输入法下也能按快捷键说话" : model.permissions.inputMonitoringGranted ? "权限有了，监听还没接上" : "需要输入监控", ready: model.globalHotkeyActive) {
                    Button(model.permissions.inputMonitoringGranted ? "重新接入" : "允许输入监控") { model.requestInputMonitoring() }
                }
                if !model.installationPathValid {
                    Text("这是未安装的构建副本。请用安装包装到系统输入法目录。")
                        .font(.system(size: 12)).foregroundStyle(.orange).padding(.top, 6)
                }
                Button("打开系统输入法设置") { InputSourceInstall.openSystemInputSourceSettings() }
                    .font(.system(size: 12))
                    .padding(.top, 8)
            }

            SettingsSection(title: "试一下", caption: "点进输入框，按住 \(model.pushToTalk.shortLabel)。当前是 \(model.currentDirection.title)。") {
                TextEditor(text: $model.testText)
                    .focused($testFocused)
                    .font(.system(size: 17, design: .rounded))
                    .frame(height: 108)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .accessibilityLabel("听写测试输入框")
                HStack {
                    Text(model.completedSessions > 0 ? "这次已经提交 \(model.completedSessions) 次" : "也可以在备忘录里试")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空") { model.coordinator.cancel(); model.testText = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: - Models Tab
    private var models: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                modelTile(title: "语音", ready: model.speechModelReady, detail: model.speechModelDetail)
                modelTile(title: "翻译", ready: model.translationModelReady, detail: model.translationModelDetail)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("语音识别模型").font(.system(size: 16, weight: .semibold))
                ForEach(SpeechModel.allCases) { speechModel in
                    speechModelRow(speechModel)
                }
            }
            Text("千问权重不随安装包提供，仅点击下载后保存到本机。两个版本可分别下载和删除，仅加载当前使用的版本。首版为最终稿识别，每次最多 30 秒；翻译与可选 AI 润色保持不变。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button {
                Task { await model.downloadModels() }
            } label: {
                HStack {
                    if model.isPreparingModels || model.isChecking { ProgressView().controlSize(.small) }
                    Text(model.isPreparingModels ? "正在准备…" : model.isChecking ? "正在检查…" : "下载当前语言所需模型")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isPreparingModels || model.isChecking || model.isListening || model.asrModels.isDownloading)
            Text("Apple 语音和翻译资产由系统管理。千问采用 mlx-community 转换的 Apache-2.0 权重，下载源为 Hugging Face。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func speechModelRow(_ selected: SpeechModel) -> some View {
        let active = model.speechModel == selected
        let installed = model.asrModels.installed.contains(selected)
        let downloading = model.asrModels.downloading == selected
        let busy = model.isListening || model.isChecking || model.isPreparingModels || model.asrModels.isDownloading
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: active ? "checkmark.circle.fill" : "waveform")
                    .foregroundStyle(active ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.title).font(.system(size: 14, weight: .semibold))
                    Text(selected.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if downloading {
                    Button("取消") { model.asrModels.cancelDownload() }
                } else if selected == .apple || installed {
                    if active && model.speechModelReady {
                        Text("使用中").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    } else {
                        Button(active ? "重试加载" : "使用") { model.selectSpeechModel(selected) }.disabled(busy)
                    }
                    if installed {
                        Menu {
                            Button("重新下载修复") { Task { await model.downloadSpeechModel(selected) } }
                            Button("删除模型…", role: .destructive) { deletingSpeechModel = selected }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(busy)
                    }
                } else {
                    Button("下载") { Task { await model.downloadSpeechModel(selected) } }.disabled(busy)
                }
            }
            if downloading {
                ProgressView(value: model.asrModels.progress)
                Text(model.asrModels.activity).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Theme.accent.opacity(0.5) : Color.secondary.opacity(0.15)))
    }

    // MARK: - Helper UI Components
    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: on ? .semibold : .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(on ? Theme.cardBackground : Color.clear, in: Capsule(style: .continuous))
                .shadow(color: on ? .black.opacity(0.06) : .clear, radius: 6, y: 1)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggleRow(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: value).labelsHidden()
        }
        .padding(.vertical, 6)
    }

    private func modelTile(title: String, ready: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle().fill(ready ? Theme.ready : Color.orange.opacity(0.8)).frame(width: 8, height: 8)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func checkRow<Action: View>(_ number: String, title: String, detail: String, ready: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(ready ? Theme.ready.opacity(0.16) : Theme.fill)
                if ready {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ready)
                } else {
                    Text(number).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !ready { action().controlSize(.small) }
        }
        .padding(.vertical, 6)
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    var caption: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
    }
}
