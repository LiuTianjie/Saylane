import Foundation

/// Bounded metadata-only trace. Never records ordinary key codes, text, or audio.
@MainActor
enum InputDiagnostics {
    private static var entries: [[String: String]] = []
    static func record(_ stage: String, _ detail: String = "") {
        entries.append(["time": ISO8601DateFormatter().string(from: Date()), "stage": stage, "detail": detail])
        entries = Array(entries.suffix(60))
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = root.appendingPathComponent("RTranslate/Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appendingPathComponent("input-session.json"), options: .atomic)
        } catch { NSLog("RTranslate diagnostic write failed: %@", error.localizedDescription) }
    }
}
