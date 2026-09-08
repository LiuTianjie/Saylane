import SwiftUI

struct FinalPolishSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var notice: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "AI 最终润色（可选）", subtitle: "默认关闭。普通识别和实时翻译保持原样，只在松手后对完整内容调用一次大模型。") {
                Toggle("启用 AI 最终润色", isOn: $model.finalPolishEnabled)
                Text("开启后会向下方接口发送本次原始识别文字、源语言、目标语言和译文草稿，不发送音频，也不读取输入框的其他内容。远程服务可能保存文本并产生费用，取决于你选择的服务。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("请求失败或超过 8 秒，提交普通结果；Esc 仍取消整次听写。即使语言相同，开启本选项后也会进行同语言润色。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            SettingsCard(title: "模型连接", subtitle: "支持兼容 Chat Completions 的服务；请填写完整接口地址，不会自动补全或选择服务商。") {
                TextField("接口地址（以 /chat/completions 结尾）", text: $model.finalPolishEndpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("服务商提供的模型 ID", text: $model.finalPolishModel).textFieldStyle(.roundedBorder)
                SecureField("API Key（不回显已保存的密钥）", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存密钥到钥匙串") { saveKey() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("删除此接口的密钥") { deleteKey() }
                }
                Text("密钥按接口地址分别保存，不写入普通配置。更换地址后需为新地址单独保存密钥。本机 localhost 服务可不填密钥。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let notice { Text(notice).font(.system(size: 12)).textSelection(.enabled) }
                if model.finalPolishEnabled && configuration == nil {
                    Text("模型连接尚未配置完整；本次会保留普通结果，不会向未配置的地址发送文本。")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
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
            key = ""; notice = "已保存。密钥仅用于此接口，未发送测试请求。"
        } catch { notice = error.localizedDescription }
    }
    private func deleteKey() {
        do {
            let config = try FinalPolishConfiguration(endpoint: model.finalPolishEndpoint, model: model.finalPolishModel)
            try PolishKeychain.delete(endpoint: config.endpoint)
            key = ""; notice = "已删除此接口的密钥。"
        } catch { notice = error.localizedDescription }
    }
}
