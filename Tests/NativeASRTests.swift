import AVFoundation
import Foundation

@main struct NativeASRTests {
    static func main() async throws {
        let process = NativeASRProcess()
        let output = try process.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["中文识别\n"])
        precondition(output == "中文识别\n")
        let cancelled = NativeASRProcess()
        cancelled.cancel()
        do {
            _ = try cancelled.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
            fatalError("pre-cancelled process started")
        } catch is CancellationError {}
        let active = NativeASRProcess()
        let task = Task.detached {
            try active.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        active.cancel()
        do { _ = try await task.value; fatalError("cancelled process succeeded") } catch {}
        precondition(Date().timeIntervalSince(start) < 3, "cancellation failed to reap promptly")
        do {
            _ = try NativeASRProcess().run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
            fatalError("nonzero exit accepted")
        } catch {}
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("asr-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try NativeASRModel.writeWAV([Float](repeating: 0.125, count: 1600), to: wav)
        let file = try AVAudioFile(forReading: wav)
        precondition(file.length == 1600 && file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        precondition(NativeASRModel.sanitize("/sil") == "")
        precondition(NativeASRModel.sanitize("  <|zh|>你好io> ") == "你好")
        precondition(NativeASRModel.sanitize("peopleio>.") == "people.")

        let cleanupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-asr-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cleanupRoot) }
        try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = now.addingTimeInterval(-(7 * 60 * 60))
        let recentDate = now.addingTimeInterval(-(5 * 60))
        func makeDirectory(_ name: String, modified: Date) throws -> URL {
            let url = cleanupRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let staleRequest = try makeDirectory("saylane-asr-\(UUID().uuidString)", modified: oldDate)
        let recentRequest = try makeDirectory("saylane-asr-\(UUID().uuidString)", modified: recentDate)
        let exactBoundaryRequest = try makeDirectory(
            "saylane-asr-\(UUID().uuidString)", modified: now.addingTimeInterval(-(6 * 60 * 60))
        )
        let unrelatedDirectory = try makeDirectory("another-app-stale", modified: oldDate)
        let prefixCollision = try makeDirectory("saylane-asr-not-a-request", modified: oldDate)
        let matchingRegularFile = cleanupRoot.appendingPathComponent("saylane-asr-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: matchingRegularFile)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: matchingRegularFile.path)
        let symlinkTarget = try makeDirectory("symlink-target", modified: oldDate)
        let matchingSymlink = cleanupRoot.appendingPathComponent("saylane-asr-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: matchingSymlink, withDestinationURL: symlinkTarget)

        NativeASRModel.cleanupStaleTemporaryAudio(in: cleanupRoot, olderThan: 6 * 60 * 60, now: now)
        precondition(!FileManager.default.fileExists(atPath: staleRequest.path),
                     "stale saylane-asr request directories must be removed")
        precondition(!FileManager.default.fileExists(atPath: exactBoundaryRequest.path),
                     "request directories at the stale-age boundary must be removed")
        precondition(FileManager.default.fileExists(atPath: recentRequest.path),
                     "active or recent request directories must be preserved")
        precondition(FileManager.default.fileExists(atPath: unrelatedDirectory.path),
                     "cleanup must preserve other applications' temporary directories")
        precondition(FileManager.default.fileExists(atPath: prefixCollision.path),
                     "cleanup must require the exact UUID request-directory format")
        precondition(FileManager.default.fileExists(atPath: matchingRegularFile.path),
                     "cleanup must preserve regular files even when their names match")
        precondition(FileManager.default.fileExists(atPath: matchingSymlink.path),
                     "cleanup must preserve symbolic links even when their names match")

        let missingRoot = cleanupRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        NativeASRModel.cleanupStaleTemporaryAudio(in: missingRoot, olderThan: 6 * 60 * 60, now: now)

        print("PASS: native helper output, cancellation/reaping, failure, 16kHz mono WAV, SenseVoice tags and scoped stale-audio cleanup")
    }
}
