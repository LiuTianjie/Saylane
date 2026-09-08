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
        // Only Sendable continuation and owned PCM cross the realtime callback boundary.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let copy = PCMCopy.copy(buffer) else {
                continuation.finish(throwing: SpeechEngineError.invalidFormat)
                return
            }
            if case .dropped = continuation.yield(AudioFrame(buffer: copy)) {
                continuation.finish(throwing: SessionFailure.audioOverflow)
            }
        }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            continuation.finish(throwing: SpeechEngineError.invalidFormat)
        }
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
        return stream
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
