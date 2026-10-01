import SwiftUI

struct OverlayView: View {
    @Bindable var model: OverlayModel

    var body: some View {
        content
            .frame(minWidth: waveformVisible ? 210 : 160)
            .padding(.horizontal, waveformVisible ? 14 : 18)
            .padding(.vertical, textVisible ? 10 : (waveformVisible ? 10 : 9))
            .overlay {
                CapsuleSweep(token: model.sweepID)
                    .clipShape(Capsule(style: .continuous))
            }
    }

    private var waveformVisible: Bool {
        model.languageSwitch == nil
            && model.completion == nil
            && model.phase != .error
            && model.phase != .polishing
            && model.phase != .finalizing
    }

    private var textVisible: Bool {
        model.showsText && (!model.sourceText.isEmpty || !model.translatedText.isEmpty)
            && (model.phase == .listening || model.phase == .preparing || model.phase == .finalizing || model.phase == .polishing)
    }

    private var statusWord: String {
        switch model.phase {
        case .preparing: return String(localized: "准备中")
        case .listening: return String(localized: "正在听")
        case .finalizing: return String(localized: "正在整理")
        case .polishing: return String(localized: "AI 润色中")
        default: return ""
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .error {
            overlayLine(icon: model.noticeIsWarning ? "exclamationmark.circle.fill" : "info.circle.fill",
                        iconColor: model.noticeIsWarning ? .orange : .secondary, text: model.statusText)
        } else if let feedback = model.completion {
            overlayLine(icon: feedback.isWarning ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                        iconColor: feedback.isWarning ? Color.orange : Color(red: 0.18, green: 0.70, blue: 0.48),
                        text: feedback.message)
        } else if model.phase == .polishing || model.phase == .finalizing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(statusWord)
                        .font(.system(size: 12, weight: .medium))
                    Text("Esc")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(String(localized: "取消"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if textVisible { textLines }
            }
            .accessibilityElement(children: .combine)
        } else if let notice = model.languageSwitch {
            Text(notice.title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityLabel(notice.from == notice.to
                    ? notice.title
                    : String(localized: "\(notice.title)，我说\(notice.from)，写成\(notice.to)"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Waveform(levels: model.levels, active: model.phase == .listening || model.phase == .preparing)
                    Text(statusWord)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.phase == .listening ? .primary : .secondary)
                        .fixedSize()
                    if model.sourceLanguageName != model.targetLanguageName, !model.targetLanguageName.isEmpty {
                        Text("\(model.sourceLanguageName) → \(model.targetLanguageName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if textVisible { textLines }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var textLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.sourceText.isEmpty, model.translatedText != model.sourceText {
                Text(model.sourceText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !model.translatedText.isEmpty {
                Text(model.translatedText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.head)
            } else if !model.sourceText.isEmpty {
                Text(model.sourceText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func overlayLine(icon: String, iconColor: Color, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(iconColor)
            Text(text).lineLimit(2)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(maxWidth: 460)
        .accessibilityElement(children: .combine)
    }
}

private struct Waveform: View {
    let levels: [Float]
    var active: Bool
    private let barWidth: CGFloat = 2.6
    private let spacing: CGFloat = 2.2
    private let minBar: CGFloat = 4.0
    private let maxBar: CGFloat = 20.0
    private let visible = 38

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                Capsule(style: .continuous)
                    .fill(barColor(for: index))
                    .frame(width: barWidth, height: height(for: level, at: index))
            }
        }
        .frame(width: CGFloat(visible) * (barWidth + spacing) - spacing, height: maxBar)
        .animation(.easeOut(duration: 0.08), value: levels)
    }

    private var bars: [Float] {
        let slice = Array(levels.suffix(visible))
        if slice.count == visible { return slice }
        return Array(repeating: 0, count: visible - slice.count) + slice
    }

    private func barColor(for index: Int) -> Color {
        let edgeDist = min(index, visible - 1 - index)
        let alpha = edgeDist < 3 ? Double(edgeDist + 1) / 4.0 : 1.0
        return active ? Color.primary.opacity(0.88 * alpha) : Color.primary.opacity(0.28 * alpha)
    }

    private func height(for level: Float, at index: Int) -> CGFloat {
        let floor: Float = active ? 0.12 : 0.06
        let rawHeight = minBar + (maxBar - minBar) * CGFloat(max(0, min(1, max(level, floor))))
        let edgeDist = min(index, visible - 1 - index)
        let taper: CGFloat = edgeDist == 0 ? 0.6 : (edgeDist == 1 ? 0.85 : 1.0)
        return rawHeight * taper
    }
}

private struct CapsuleSweep: View {
    let token: Int
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let band = geo.size.width * 0.34
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.18),
                    Color.white.opacity(0.72),
                    Color.white.opacity(0.18),
                    Color.white.opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band, height: geo.size.height * 1.65)
            .rotationEffect(.degrees(16))
            .offset(x: -band + progress * (geo.size.width + band * 2))
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .onChange(of: token) { _, value in
            guard value > 0 else { return }
            progress = 0
            withAnimation(.easeInOut(duration: 0.58)) { progress = 1 }
        }
    }
}
