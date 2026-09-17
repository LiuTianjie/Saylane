import SwiftUI

struct RimeDictionaryUpdateView: View {
    let model: RimeDictionaryUpdateModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("dictionaryUpdateStatus")
                if let result = model.result, result.hasUpdate {
                    Button("查看 \(result.latest.shortRevision)") { openURL(result.releaseURL) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                if model.isChecking {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }.controlSize(.small)
                } else {
                    Button("检查更新") { model.check() }.controlSize(.small)
                }
            }
        } label: {
            Text("雾凇词库")
            Text("当前版本 \(model.currentVersion)")
        }
    }

    private var statusLine: String {
        if let result = model.result {
            return "\(model.statusText) · \(result.checkedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return model.statusText
    }

    private var isFailure: Bool {
        if case .failed = model.state { return true }
        return false
    }
}
