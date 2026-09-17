import AVFoundation
import Darwin
import Foundation

/// Official standalone CPU helpers. Each request owns its process and private
/// temporary WAV; cancellation/timeout reaps it before the next model can run.
actor NativeASRModel: LoadedSpeechModel {
    private let variant: SpeechModel
    private let directory: URL
    private let executable: URL
    private var lastDuration: Double = 0

    private init(_ variant: SpeechModel, directory: URL, executable: URL) {
        self.variant = variant; self.directory = directory; self.executable = executable
    }

    static func load(_ variant: SpeechModel) async throws -> NativeASRModel {
        let manifest = try variant.manifest()
        try await ASRModelInstaller().verify(manifest)
        let name = variant == .senseVoice ? "llama-funasr-sensevoice" : "llama-funasr-cli"
        guard let resources = Bundle.main.resourceURL else { throw ASRModelError.manifest }
        let executable = resources.appendingPathComponent("Runtime").appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ASRModelError.manifest }
        return NativeASRModel(variant, directory: manifest.directory(), executable: executable)
    }

    func diagnostics() -> String { "nativeCPU requestSeconds=\(lastDuration) residentModel=false" }

    func transcribe(_ audio: [Float], language: String) async throws -> String {
        try Task.checkCancellation()
        guard !audio.isEmpty, audio.count <= QwenAudioBuffer.maxSamples, audio.allSatisfy(\.isFinite) else {
            throw ASRModelError.tooLong
        }
        let start = ProcessInfo.processInfo.systemUptime
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("saylane-asr-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("speech.wav")
        try Self.writeWAV(audio, to: wav)
        let arguments: [String]
        if variant == .senseVoice {
            arguments = ["-m", directory.appendingPathComponent("sensevoice-small-q8.gguf").path, "-a", wav.path]
        } else {
            arguments = ["--enc", directory.appendingPathComponent("funasr-encoder-f16.gguf").path,
                         "-m", directory.appendingPathComponent("qwen3-0.6b-q4km.gguf").path, "-a", wav.path, "-n", "1024"]
        }
        let runner = NativeASRProcess()
        let binary = executable
        let output = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runner.run(executable: binary, arguments: arguments)
            }.value
        } onCancel: { runner.cancel() }
        try Task.checkCancellation()
        lastDuration = ProcessInfo.processInfo.systemUptime - start
        return Self.sanitize(output)
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = buffer.floatChannelData?[0] else { throw SpeechEngineError.invalidFormat }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

final class NativeASRProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func run(executable: URL, arguments: [String]) throws -> String {
        let child = Process(), output = Pipe(), exited = DispatchSemaphore(value: 0)
        child.executableURL = executable; child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { _ in exited.signal() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        try? output.fileHandleForWriting.close()
        let watchdog = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        defer {
            watchdog.cancel()
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            exited.wait()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        var data = Data()
        while true {
            let chunk = try output.fileHandleForReading.read(upToCount: 16384) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= 1_048_576 else { throw ASRModelError.invalidDownload("识别输出过长") }
        }
        // EOF can precede process exit by a few instructions. Reap before status.
        exited.wait(); exited.signal()
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        guard child.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "NativeASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地识别未完成或已取消，请重试；长句可分段输入。"])
        }
        return text
    }
}

extension NativeASRModel {
    /// Drop leftover SenseVoice tags. Do not invent missing words.
    static func sanitize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "/sil" { return "" }
        while let range = s.range(of: #"<\|[^>]*\|>"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        s = s.replacingOccurrences(of: "io>", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
