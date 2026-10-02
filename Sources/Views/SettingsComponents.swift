import SwiftUI

/// Shared by onboarding and settings so row spacing and control alignment stay consistent.
struct SettingsSection<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer

    init(@ViewBuilder content: () -> Content,
         @ViewBuilder header: () -> Header = { EmptyView() },
         @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 0) {
                if Header.self != EmptyView.self {
                    header
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                    Divider().opacity(0.45)
                }
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.vertical, 14)
                        if row.id != rows.last?.id {
                            Divider().opacity(0.45).padding(.horizontal, 18)
                        }
                    }
                }
            }
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline.opacity(0.55)))
            if Footer.self != EmptyView.self {
                footer
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsNavigationButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(width: 20)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).frame(height: 42)
            .background(selected ? Theme.cardBackground : hovered ? Theme.fill : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SaylaneBrand: View {
    var large = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: large ? 28 : 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: large ? 60 : 34, height: large ? 60 : 34)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: large ? 18 : 11))
            if !large { Text("Saylane").font(.system(size: 20, weight: .semibold)) }
        }
        .accessibilityLabel("Saylane")
    }
}

struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 20) {
            configuration.label
            Spacer(minLength: 16)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden().toggleStyle(SwitchToggleStyle(tint: Theme.accent))
        }
    }
}

struct SettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) { configuration.label }
            Spacer(minLength: 16)
            configuration.content
        }
    }
}

/// Keep the guide discoverable even while this accessory window is inactive.
struct SettingsGuideButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(hovered ? 0.32 : 0.12)))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
    }
}
