import SwiftUI

struct RimeDictionaryUpdateView: View {
    let model: RimeDictionaryUpdateModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("词库更新")
                        .font(.system(size: 14, weight: .medium))
                    Text("雾凇拼音 · 当前版本 \(model.currentVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isChecking {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }
                        .controlSize(.small)
                } else {
                    Button("检查词库更新") { model.check() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Text(model.statusText)
                .font(.system(size: 12))
                .foregroundStyle(isFailure ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dictionaryUpdateStatus")
            if let result = model.result {
                HStack {
                    Text("检查于 \(result.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if result.hasUpdate {
                        Button("查看上游版本 \(result.latest.shortRevision)") { openURL(result.releaseURL) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = model.state { return true }
        return false
    }
}
