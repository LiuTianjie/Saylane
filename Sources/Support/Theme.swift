import SwiftUI

enum Theme {
    static let accent = Color(red: 0.25, green: 0.43, blue: 0.96)
    static let settingsBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.11, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
    })
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.14, alpha: 1) : NSColor(calibratedWhite: 0.935, alpha: 1)
    })
    static let cardBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.17, alpha: 1) : .white
    })

    static let radiusHUD: CGFloat = 20
    static let radiusCard: CGFloat = 16
    static let radiusSmall: CGFloat = 10

    static let listening = Color(red: 0.91, green: 0.29, blue: 0.36)
    static let ready = Color(red: 0.18, green: 0.70, blue: 0.48)
    static let hairline = Color.primary.opacity(0.08)
    static let hairlineStrong = Color.primary.opacity(0.14)
    static let fill = Color.primary.opacity(0.05)
    static let fillStrong = Color.primary.opacity(0.08)
}

struct Keycap: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(Theme.fillStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            )
    }
}

struct SettingsCard<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}
