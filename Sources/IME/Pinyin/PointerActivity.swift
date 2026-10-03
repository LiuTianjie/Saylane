import CoreGraphics
import Foundation

/// Whether the pointer was used while a modifier was held. InputMethodKit
/// hands an input method keys only, so a Shift-click or Shift-drag reaches
/// it as a bare Shift press and release. The window server keeps, for every
/// kind of event, how long ago the last one happened; reading that needs no
/// permission and sees no positions or contents. Scrolling is not counted:
/// a trackpad keeps scrolling for a second after the fingers lift, and a
/// tap right after it must still switch.
enum PointerActivity {
    private static let kinds: [CGEventType] = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    /// `hold` is how long the modifier was down; `endedAt` is the system uptime of its release.
    static func used(_ hold: TimeInterval, _ endedAt: TimeInterval) -> Bool {
        guard hold > 0, endedAt > 0 else { return false }
        // The window since the modifier went down, as seen from now; a little
        // margin for a click that landed just before the press was noticed.
        let window = ProcessInfo.processInfo.systemUptime - (endedAt - hold) + 0.05
        return kinds.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < window }
    }
}
