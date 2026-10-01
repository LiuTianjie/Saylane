import Foundation

/// Bounded metadata-only trace. Never records ordinary key codes, text, or audio.
/// Each process writes its own file (`Diagnostics/ime.json`, `Diagnostics/app.json`).
@MainActor
enum InputDiagnostics {
    /// Set once at process start, before the first record.
    static var channel = "app"
    private static var entries: [[String: String]] = []
    private static var pendingWrite: Task<Void, Never>?
    private static let writer = DiagnosticWriter()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()
    private static let capacity = 500

    static func record(_ stage: String, _ detail: String = "") {
        let time = formatter.string(from: Date())
        if var last = entries.last, last["stage"] == stage, last["detail"] == detail {
            // The same thing again: count it instead of pushing useful entries out.
            last["count"] = String((Int(last["count"] ?? "1") ?? 1) + 1)
            last["until"] = time
            entries[entries.count - 1] = last
        } else {
            entries.append(["time": time, "stage": stage, "detail": detail])
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
        guard pendingWrite == nil else { return }
        // Bound write frequency and keep file I/O off the main actor.
        pendingWrite = Task {
            try? await Task.sleep(for: .milliseconds(200))
            let snapshot = entries
            await writer.persist(snapshot, channel: channel)
            pendingWrite = nil
            // Events received during I/O must not be lost if no further event comes.
            if entries != snapshot { scheduleFlush() }
        }
    }

    private static func scheduleFlush() {
        pendingWrite = Task {
            let snapshot = entries
            await writer.persist(snapshot, channel: channel)
            pendingWrite = nil
            if entries != snapshot { scheduleFlush() }
        }
    }
}

private actor DiagnosticWriter {
    func persist(_ entries: [[String: String]], channel: String) {
        let dir = AppDirectories.diagnostics
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appendingPathComponent("\(channel).json"), options: .atomic)
        } catch { NSLog("Saylane diagnostic write failed: %@", error.localizedDescription) }
    }
}
