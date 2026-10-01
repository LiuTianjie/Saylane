import Foundation

/// Bounded metadata-only trace. Never records ordinary key codes, text, or audio.
@MainActor
enum InputDiagnostics {
    private static var entries: [[String: String]] = []
    private static var pendingWrite: Task<Void, Never>?
    private static let writer = DiagnosticWriter()
    private static let formatter = ISO8601DateFormatter()

    static func record(_ stage: String, _ detail: String = "") {
        entries.append(["time": formatter.string(from: Date()), "stage": stage, "detail": detail])
        entries = Array(entries.suffix(300))
        guard pendingWrite == nil else { return }
        // Bound write frequency and keep file I/O off the IME/ASR main actor.
        pendingWrite = Task {
            try? await Task.sleep(for: .milliseconds(200))
            let snapshot = entries
            await writer.persist(snapshot)
            pendingWrite = nil
            // Events received during I/O must not be lost if no further event comes.
            if entries != snapshot { scheduleFlush() }
        }
    }

    private static func scheduleFlush() {
        pendingWrite = Task {
            let snapshot = entries
            await writer.persist(snapshot)
            pendingWrite = nil
            if entries != snapshot { scheduleFlush() }
        }
    }
}

private actor DiagnosticWriter {
    func persist(_ entries: [[String: String]]) {
        let dir = AppDirectories.diagnostics
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appendingPathComponent("input-session.json"), options: .atomic)
        } catch { NSLog("Saylane diagnostic write failed: %@", error.localizedDescription) }
    }
}
