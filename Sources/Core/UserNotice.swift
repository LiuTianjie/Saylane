import Foundation

/// The single user-feedback type. The level decides how it is shown; no caller
/// opens a window or picks a channel on its own.
struct UserNotice: Equatable, Identifiable, Sendable {
    enum Level: Equatable, Sendable {
        /// Shown in the HUD for a few seconds. Never steals focus.
        case transient
        /// Something the user must fix. HUD shows the reason; the settings banner
        /// keeps it until it is cleared or the underlying condition resolves.
        case actionable
        /// Logged only.
        case diagnostic
    }

    /// Where the settings window should open if the user follows up.
    enum Destination: Equatable, Sendable {
        case none, permissions, models, voice, screen
    }

    let id: UUID
    var level: Level
    var message: String
    var destination: Destination

    init(id: UUID = UUID(), _ level: Level, _ message: String, destination: Destination = .none) {
        self.id = id
        self.level = level
        self.message = message
        self.destination = destination
    }

    static func transient(_ message: String) -> UserNotice { UserNotice(.transient, message) }
    static func actionable(_ message: String, _ destination: Destination = .none) -> UserNotice {
        UserNotice(.actionable, message, destination: destination)
    }
    static func diagnostic(_ message: String) -> UserNotice { UserNotice(.diagnostic, message) }

    /// How long a HUD presentation of this notice stays visible.
    var hudDuration: Double {
        switch level {
        case .transient: return 2.6
        case .actionable: return 4.5
        case .diagnostic: return 0
        }
    }
}
