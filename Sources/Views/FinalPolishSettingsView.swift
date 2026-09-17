import SwiftUI

/// Everything that repairs text after recognition: on-device rules and vocabulary,
/// the optional language model, and the one connection both uses share.
struct FinalPolishSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var notice: String?

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("自动修正口误", isOn: $model.dictationCleanupEnabled)
                .help("去掉嗯、呃和口吃重复；「不对，我是说…」「不是 A，是 B」直接写成改正后的内容。标记词必须独立成句，「不对称」「这个答案不对，我们再看看」不会被改。")
            Toggle("个人词库", isOn: $model.speechHotwordsEnabled)
                .help("识别后按读音或拼写改成词库写法；Apple 和 Qwen 识别时也优先考虑这些词。中文按拼音匹配并容忍 z/zh、n/l、in/ing；英文容忍少量拼写差异。最多 50 个。")
            if model.speechHotwordsEnabled {
                TextField("每行一个词；常被听错的写法用 | 标在后面，如 Saylane|赛兰|塞蓝", text: $model.speechHotwords, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(size: 12.5))
                    .labelsHidden()
            }
        } header: {
            Text("本地修正")
        } footer: {
            Text("在本机同步完成，不联网，边说边生效。识别结果先经过这里，再交给大模型。")
        }
        .disabled(model.isListening)

        Section {
            Toggle("语音输入", isOn: $model.finalPolishEnabled)
                .help("说写语言相同时只修同音错字、口误和标点，不改措辞；需要翻译时用整句原文修正译文")
            Toggle("截屏翻译", isOn: $model.screenPolishEnabled)
                .help("结合周边文字修正划选区域的译文")
        } header: {
            Text("大模型校对")
        } footer: {
            Text("松手后调用一次，本地结果先上屏，模型返回后替换。失败、超过 8 秒或改动过大都保留本地结果。只发送文字。")
        }
        .disabled(model.isListening)

        Section {
            TextField("接口地址", text: $model.finalPolishEndpoint, prompt: Text("https://…/v1/chat/completions"))
            TextField("模型", text: $model.finalPolishModel, prompt: Text("模型 ID"))
            SecureField("API Key", text: $key, prompt: Text(configuration?.isLocal == true ? "本机服务可不填" : "不回显已保存的密钥"))
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
            if (model.finalPolishEnabled || model.screenPolishEnabled) && configuration == nil {
                Text("连接尚未配置完整；会保留本地结果，不会向未配置的地址发送文本。").foregroundStyle(.orange)
            } else {
                Text("兼容 Chat Completions 的服务都可以，包括本机的 Ollama / LM Studio。密钥按接口地址分别存在钥匙串。")
            }
        }
        .disabled(model.isListening)
        .onChange(of: model.finalPolishEndpoint) { _, _ in key = ""; notice = nil }
    }

    private var configuration: FinalPolishConfiguration? {
        try? FinalPolishConfiguration(endpoint: model.finalPolishEndpoint, model: model.finalPolishModel)
    }
    private func saveKey() {
        do {
            let config = try FinalPolishConfiguration(endpoint: model.finalPolishEndpoint, model: model.finalPolishModel)
            try PolishKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: config.endpoint)
            key = ""; notice = "已保存"
        } catch { notice = error.localizedDescription }
    }
    private func deleteKey() {
        do {
            let config = try FinalPolishConfiguration(endpoint: model.finalPolishEndpoint, model: model.finalPolishModel)
            try PolishKeychain.delete(endpoint: config.endpoint)
            key = ""; notice = "已删除"
        } catch { notice = error.localizedDescription }
    }
}
