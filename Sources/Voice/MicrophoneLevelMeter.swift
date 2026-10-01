import AVFoundation
import Foundation
import Observation

/// Short-lived input meter for the onboarding trial page. Never used during a session.
@MainActor @Observable
final class MicrophoneLevelMeter {
    private(set) var level: Float = 0
    private(set) var isRunning = false
    @ObservationIgnored private var capture: AudioCaptureService?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var smoothed: Float = 0
    @ObservationIgnored private var generation = 0

    func start() {
        guard !isRunning else { return }
        let service = AudioCaptureService()
        guard let stream = try? service.startStream() else { return }
        capture = service
        isRunning = true
        generation += 1
        let token = generation
        pump = Task { [weak self] in
            do {
                for try await frame in stream {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    let raw = AudioLevel.normalized(from: frame.buffer)
                    self.smoothed += (raw - self.smoothed) * (raw > self.smoothed ? 0.7 : 0.25)
                    self.level = self.smoothed
                }
            } catch {}
            guard let self, self.generation == token else { return }
            self.capture?.stop()
            self.capture = nil
            self.isRunning = false
        }
    }

    func stop() {
        generation += 1
        pump?.cancel()
        pump = nil
        capture?.stop()
        capture = nil
        isRunning = false
        level = 0
        smoothed = 0
    }
}
