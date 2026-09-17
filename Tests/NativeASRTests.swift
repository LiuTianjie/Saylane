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
        print("PASS: native helper output, cancellation/reaping, failure, 16kHz mono WAV and SenseVoice tag cleanup")
    }
}
