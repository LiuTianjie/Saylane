import SwiftUI

struct CandidateBarView: View {
    let items: [PinyinCandidate]
    let selected: Int
    let pageIndex: Int
    let pageCount: Int
    var preedit: String = ""
    var associating: Bool = false
    var expanded: Bool = false
    var canExpand: Bool = false
    var onPick: (Int) -> Void
    var onPage: (Int) -> Void = { _ in }
    var onToggleExpand: () -> Void = {}

    private let barVerticalInset: CGFloat = 5
    private let barHorizontalInset: CGFloat = 4
    private let rowHorizontalInset: CGFloat = 4
    private let itemHorizontalInset: CGFloat = 8
    private let itemVerticalInset: CGFloat = 6
    private let innerHighlightRadius: CGFloat = 8

    private var firstRow: ArraySlice<PinyinCandidate> { items.prefix(9) }
    private var secondRow: ArraySlice<PinyinCandidate> {
        items.count > 9 ? items.suffix(from: 9) : []
    }

    private var barRadius: CGFloat { expanded ? 14 : 22 }
    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: barRadius, style: .continuous)
    }
    private var hasLeadingChip: Bool { !preedit.isEmpty || associating }
    private var hasTrailingChrome: Bool { pageCount > 1 || canExpand }
    private var leadingHighlightInset: CGFloat { barHorizontalInset + rowHorizontalInset }
    private var trailingHighlightInset: CGFloat { barHorizontalInset + rowHorizontalInset }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if !preedit.isEmpty {
                Text(preedit)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                barDivider
            } else if associating {
                Text("联想")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                barDivider
            }

            VStack(alignment: .leading, spacing: 2) {
                candidateRow(Array(firstRow), offset: 0, selected: selected)
                if expanded, !secondRow.isEmpty {
                    candidateRow(Array(secondRow), offset: 9, selected: selected)
                }
            }
            .padding(.horizontal, rowHorizontalInset)

            if hasTrailingChrome {
                barDivider
                HStack(spacing: 2) {
                    if pageCount > 1 {
                        pageButton(system: "chevron.left", delta: -1, label: "上一页")
                        Text("\(pageIndex + 1)/\(pageCount)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 28)
                        pageButton(system: "chevron.right", delta: 1, label: "下一页")
                    }
                    if canExpand {
                        Button(action: onToggleExpand) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded ? "收起候选" : "展开候选")
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, barVerticalInset)
        .padding(.horizontal, barHorizontalInset)
        .background(Theme.cardBackground, in: barShape)
        .clipShape(barShape)
        .overlay(barShape.strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityValue(associating ? "联想 第\(pageIndex + 1)/\(max(pageCount, 1))页" : "第\(pageIndex + 1)/\(max(pageCount, 1))页")
    }

    private func candidateRow(_ row: [PinyinCandidate], offset: Int, selected: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(row.enumerated()), id: \.offset) { local, item in
                let index = offset + local
                let selectedHere = index == selected
                let isLeadingCap = !hasLeadingChip && offset == 0 && local == 0
                let isTrailingCap = !hasTrailingChrome && offset == 0 && local == row.count - 1
                Button {
                    onPick(index)
                } label: {
                    HStack(spacing: 5) {
                        Text("\(local + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(selectedHere ? Theme.accent : Color.secondary.opacity(0.8))
                            .frame(minWidth: 8, alignment: .trailing)
                        Text(item.word)
                            .font(.system(size: 15, weight: selectedHere ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                        if !item.comment.isEmpty {
                            Text(item.comment)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, itemHorizontalInset)
                    .padding(.vertical, itemVerticalInset)
                    .background {
                        if selectedHere {
                            candidateHighlight(isLeadingCap: isLeadingCap, isTrailingCap: isTrailingCap)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.comment.isEmpty ? "\(local + 1) \(item.word)" : "\(local + 1) \(item.word) \(item.comment)")
            }
        }
    }

    private func candidateHighlight(isLeadingCap: Bool, isTrailingCap: Bool) -> some View {
        let capRadius = max(barRadius - 1, innerHighlightRadius)
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: isLeadingCap ? capRadius : innerHighlightRadius,
                bottomLeading: isLeadingCap ? capRadius : innerHighlightRadius,
                bottomTrailing: isTrailingCap ? capRadius : innerHighlightRadius,
                topTrailing: isTrailingCap ? capRadius : innerHighlightRadius
            ),
            style: .continuous
        )
        .fill(Theme.accent.opacity(0.16))
        .padding(.leading, isLeadingCap ? -leadingHighlightInset : 0)
        .padding(.trailing, isTrailingCap ? -trailingHighlightInset : 0)
        .padding(.vertical, (isLeadingCap || isTrailingCap) ? -barVerticalInset : 0)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Theme.hairlineStrong)
            .frame(width: 1, height: 18)
    }

    private func pageButton(system: String, delta: Int, label: String) -> some View {
        Button {
            onPage(delta)
        } label: {
            Image(systemName: system)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
