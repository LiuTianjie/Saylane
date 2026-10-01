import AVFoundation

@MainActor
final class AudioCaptureService: AudioCapturing {
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    private var configObserver: NSObjectProtocol?

    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error> {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechEngineError.invalidFormat }
        let (stream, continuation) = AsyncThrowingStream<AudioFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        self.engine = engine
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 2048, format: format,
                         block: Self.makeTap(continuation: continuation))
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            continuation.finish(throwing: SpeechEngineError.invalidFormat)
        }
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
        return stream
    }

    // AVAudioNodeTapBlock is a legacy non-Sendable Objective-C block. Creating it
    // inline in startStream inherits MainActor isolation and traps on the first
    // audio callback in Swift 6. Keep the factory nonisolated and its result
    // Sendable; only the continuation and an owned PCM copy cross this boundary.
    nonisolated static func makeTap(continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let copy = PCMCopy.copy(buffer) else {
                continuation.finish(throwing: SpeechEngineError.invalidFormat)
                return
            }
            if case .dropped = continuation.yield(AudioFrame(buffer: copy)) {
                continuation.finish(throwing: SessionFailure.audioOverflow)
            }
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        continuation?.finish()
        continuation = nil
    }
}
