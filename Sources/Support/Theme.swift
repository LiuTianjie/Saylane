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

/// System Settings–style sidebar glyph: a small rounded tile with a white symbol.
struct SettingsGlyph: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A small inline status word used inside grouped forms; the only colour is the state dot.
struct StatusText: View {
    let text: String
    let ready: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ready ? Theme.ready : Color.orange).frame(width: 6, height: 6)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}
