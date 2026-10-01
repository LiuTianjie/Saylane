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
        } header: {
            Text("本地修正")
        } footer: {
            Text("口误和个人词库均在本机修正，不联网。常见术语默认关闭；开启后每日从维基百科和维基词典更新（CC BY-SA），不上传语音。")
        }
        .disabled(model.isListening)

        SettingsSection {
            Toggle("语音输入", isOn: model.binding(\.finalPolishEnabled))
                .help("说写语言相同时只修同音错字、口误和标点，不改措辞；需要翻译时用整句原文修正译文")
            Toggle("截屏翻译", isOn: model.binding(\.screenPolishEnabled))
                .help("结合周边文字修正划选区域的译文")
        } header: {
            Text("大模型校对")
        } footer: {
            Text("仅发送文字进行校对。先显示本地结果，校对成功后更新；失败、超时或改动过大时保留原文。")
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
