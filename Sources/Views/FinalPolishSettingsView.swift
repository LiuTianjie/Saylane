import SwiftUI

/// Everything that repairs text after recognition: on-device rules and vocabulary,
/// the optional language model, and the one connection both uses share.
struct FinalPolishSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var notice: String?

    var body: some View {
        let p = model.prefs
        SettingsSection {
            Toggle("自动修正口误", isOn: model.binding(\.dictationCleanupEnabled))
            Toggle("句末不加句号", isOn: model.binding(\.dictationDropFinalStop))
                .help("聊天里常这样写。问号和感叹号保留。")
            Toggle("中文和英文、数字之间加空格", isOn: model.binding(\.dictationSpaceBetweenScripts))
                .help("去掉嗯、呃和口吃重复；「不对，我是说…」「不是 A，是 B」直接写成改正后的内容。标记词必须独立成句，「不对称」「这个答案不对，我们再看看」不会被改。")
            Toggle("常见术语", isOn: model.binding(\.dictationGlossaryEnabled))
                .help("数学、科学、计算机、编程、生物化学和互联网热词。识别后按读音或拼写改回标准写法；人名和你们自己的词仍用个人词库。不含微信、翻译这类同音日常词。开启后每天从中文维基百科、维基词典的分类标题补新词（CC BY-SA）。")
            if p.dictationGlossaryEnabled {
                Label(String(localized: "已开启：每天联网一次，从维基百科和维基词典的分类标题获取术语（CC BY-SA）。只下载标题，不上传任何内容。"), systemImage: "network")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Toggle("个人词库", isOn: model.binding(\.speechHotwordsEnabled))
                .help("人名、公司名和你们自己的词。识别后按读音或拼写改成词库写法；Apple 和 Qwen 识别时也优先考虑。中文按拼音匹配并容忍 z/zh、n/l、in/ing；英文容忍少量拼写差异。最多 50 个，排在常见术语前面。")
            if p.speechHotwordsEnabled {
                TextField("每行一个词；常被听错的写法用 | 标在后面，如 Saylane|赛兰|塞蓝", text: model.binding(\.speechHotwords), axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(size: 12.5))
                    .labelsHidden()
            }
            Toggle("从我的修改里学习", isOn: model.binding(\.learnFromCorrections))
                .help("听写写进输入框以后，你把一个人名或术语改掉，Saylane 会记下这一对写法。改成的写法从下一次听写起提示给识别；同样的修改做过两次，以后听成原来的写法时直接替换。日常用语、数字和大段改写不学。只在本机保存词对，不保存句子。")
            if !model.corrections.corrections.isEmpty {
                LearnedCorrectionsList()
            }
        } header: {
            Text("本地修正")
        } footer: {
            Text("口误、个人词库和从修改里学到的写法都在本机处理，不联网。常见术语默认关闭；开启后每日从维基百科和维基词典更新（CC BY-SA），不上传语音。")
        }
        .disabled(model.isListening)

        SettingsSection {
            Toggle("语音输入", isOn: model.binding(\.finalPolishEnabled))
                .help("说写语言相同时只修同音错字、口误和标点，不改措辞；需要翻译时用整句原文修正译文")
            Toggle("截屏精翻", isOn: model.binding(\.screenPolishEnabled))
                .help("把划选区域里的文字整屏交给大模型翻译：按界面语境选词，品牌名和代码保持原样，译文尽量放得进原来的位置。先显示本机翻译，精翻完成后替换。")
        } header: {
            Text("大模型校对与精翻")
        } footer: {
            Text("只发送文字，不发送语音和图片。先显示本地结果，成功后更新；失败、超时或改动过大时保留本地结果。开启截屏精翻后，划选区域里识别出的文字和所在应用的名称会发送到下面配置的接口，截图本身不会发送。")
        }
        .disabled(model.isListening)

        SettingsSection {
            LabeledContent("接口地址") {
                TextField("接口地址", text: model.binding(\.finalPolishEndpoint), prompt: Text("https://…/v1/chat/completions")).labelsHidden().frame(maxWidth: 320)
            }
            LabeledContent("模型") {
                TextField("模型", text: model.binding(\.finalPolishModel), prompt: Text("模型 ID")).labelsHidden().frame(maxWidth: 320)
            }
            LabeledContent("API Key") {
                SecureField("API Key", text: $key, prompt: Text(configuration?.isLocal == true ? "本机服务可不填" : "不回显已保存的密钥")).labelsHidden().frame(maxWidth: 320)
            }
            LabeledContent("密钥") {
                HStack(spacing: 8) {
                    if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Button("保存") { saveKey() }.controlSize(.small)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("删除") { deleteKey() }.controlSize(.small)
                }
            }
        } header: {
            Text("模型连接")
        } footer: {
            if (p.finalPolishEnabled || p.screenPolishEnabled) && configuration == nil {
                Text("连接尚未配置完整；会保留本地结果，不会向未配置的地址发送文本。").foregroundStyle(.orange)
            } else {
                Text("兼容 Chat Completions 的服务都可以，包括本机的 Ollama / LM Studio。密钥按接口地址分别存在钥匙串。")
            }
        }
        .disabled(model.isListening)
        .onChange(of: p.finalPolishEndpoint) { _, _ in key = ""; notice = nil }
    }

    private var configuration: FinalPolishConfiguration? {
        try? FinalPolishConfiguration(endpoint: model.prefs.finalPolishEndpoint, model: model.prefs.finalPolishModel)
    }
    private func saveKey() {
        do {
            let config = try FinalPolishConfiguration(endpoint: model.prefs.finalPolishEndpoint, model: model.prefs.finalPolishModel)
            try PolishKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: config.endpoint)
            key = ""; notice = String(localized: "已保存")
        } catch { notice = error.localizedDescription }
    }
    private func deleteKey() {
        do {
            let config = try FinalPolishConfiguration(endpoint: model.prefs.finalPolishEndpoint, model: model.prefs.finalPolishModel)
            try PolishKeychain.delete(endpoint: config.endpoint)
            key = ""; notice = String(localized: "已删除")
        } catch { notice = error.localizedDescription }
    }
}

/// What was learned from the user's corrections: one line a pair, each of
/// which can be forgotten, and one button to forget them all.
private struct LearnedCorrectionsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let learned = model.corrections.corrections
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已学到 \(learned.items.count) 对写法").font(.system(size: 12.5))
                Spacer()
                Button("全部忘记") { model.corrections.forgetAll() }.controlSize(.small)
            }
            // A handful is shown whole; a long list scrolls inside its own frame.
            if learned.items.count <= 5 {
                rows(learned)
            } else {
                ScrollView { rows(learned) }.frame(height: 120)
            }
        }
    }

    private func rows(_ learned: LearnedCorrections) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(learned.listed) { item in
                HStack(spacing: 8) {
                    Text(verbatim: "\(item.heard) → \(item.corrected)").font(.system(size: 12.5)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Self.label(learned.standing(of: item))).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Button { model.corrections.forget(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("忘记这一对").accessibilityLabel(Text("忘记这一对"))
                }
            }
        }
    }

    private static func label(_ standing: LearnedCorrections.Standing) -> String {
        switch standing {
        case .replaces: return String(localized: "自动替换")
        case .replacesAfterNext: return String(localized: "再改一次后自动替换")
        case .hint: return String(localized: "只提示识别")
        }
    }
}
