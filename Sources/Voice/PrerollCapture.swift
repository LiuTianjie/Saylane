import AVFoundation
import Foundation

/// Opens the microphone the moment the key goes down and keeps a bounded ring of
/// owned PCM until the session asks for the stream. The first words of an
/// utterance are therefore never lost to hold detection, input-source switching
/// or model loading.
@MainActor
final class PrerollCapture: AudioCapturing {
    private let underlying: any AudioCapturing
    private let limitSeconds: TimeInterval
    private var buffered: [AudioFrame] = []
    private var bufferedSeconds: TimeInterval = 0
    private var pump: Task<Void, Never>?
    private var output: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    private var failure: Error?
    private var finished = false
    private var hasStarted = false
    private var streamTaken = false
    private var generation = 0
    private(set) var isArmed = false
    /// Sound level while buffering, so the HUD can move before the session starts.
    var onLevel: ((Float) -> Void)?

    init(underlying: (any AudioCapturing)? = nil, limit: TimeInterval = VoicePolicy.standard.prerollLimit) {
        self.underlying = underlying ?? AudioCaptureService()
        self.limitSeconds = max(0.2, limit)
    }

    /// Start capturing into the ring. Idempotent.
    func arm() throws {
        guard !isArmed else { return }
        if hasStarted { discard() }
        let stream = try underlying.startStream()
        hasStarted = true
        isArmed = true
        finished = false
        failure = nil
        generation += 1
        let token = generation
        pump = Task { [weak self] in
            do {
                for try await frame in stream {
                    guard let self, self.generation == token else { return }
                    self.receive(frame)
                }
                guard let self, self.generation == token else { return }
                self.finishOutput(error: nil)
            } catch {
                guard let self, self.generation == token else { return }
                self.finishOutput(error: error)
            }
        }
    }

    /// Frames received so far, in seconds.
    var bufferedDuration: TimeInterval { bufferedSeconds }

    private func receive(_ frame: AudioFrame) {
        guard !finished else { return }
        if isArmed { onLevel?(AudioLevel.normalized(from: frame.buffer)) }
        if let output {
            if case .dropped = output.yield(frame) {
                underlying.stop()
                isArmed = false
                finishOutput(error: SessionFailure.audioOverflow)
            }
            return
        }
        buffered.append(frame)
        bufferedSeconds += Self.seconds(of: frame)
        while bufferedSeconds > limitSeconds, buffered.count > 1 {
            bufferedSeconds -= Self.seconds(of: buffered.removeFirst())
        }
    }

    private func finishOutput(error: Error?) {
        guard !finished else { return }
        if isArmed { isArmed = false; underlying.stop() }
        finished = true
        failure = error
        if let output {
            if let error { output.finish(throwing: error) } else { output.finish() }
            self.output = nil
        }
    }

    // MARK: AudioCapturing

    /// Replay everything buffered, then continue live. Called once by the session.
    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error> {
        if !hasStarted { try arm() }
        guard !streamTaken else { throw SpeechEngineError.setupFailed }
        if let failure { throw failure }
        streamTaken = true
        let (stream, continuation) = AsyncThrowingStream<AudioFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        for frame in buffered { continuation.yield(frame) }
        buffered.removeAll()
        bufferedSeconds = 0
        if finished { continuation.finish() } else { output = continuation }
        return stream
    }

    func stop() {
        // Key-up stops hardware immediately. Let the pump drain frames that
        // already crossed the tap boundary before it finishes the output stream.
        // Cancelling this task here used to lose the tail (or the entire preroll).
        guard isArmed else { return }
        isArmed = false
        underlying.stop()
    }

    /// Nothing was said, or the gesture turned out to be something else.
    func discard() {
        generation += 1
        underlying.stop()
        pump?.cancel()
        pump = nil
        isArmed = false
        hasStarted = false
        streamTaken = false
        finished = false
        failure = nil
        buffered.removeAll()
        bufferedSeconds = 0
        output?.finish()
        output = nil
    }

    private static func seconds(of frame: AudioFrame) -> TimeInterval {
        let rate = frame.buffer.format.sampleRate
        guard rate > 0 else { return 0 }
        return Double(frame.buffer.frameLength) / rate
    }
}
