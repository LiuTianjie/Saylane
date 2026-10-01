import AVFoundation
import AppKit
import Foundation

/// Stand-ins for the microphone, the recognizer and "which application is in
/// front". They exist only in a test home (`SAYLANE_TEST_HOME`): with them the
/// built main program runs a whole dictation — talk key, session, preview,
/// final text, delivery — on a machine where nobody is speaking, and without
/// touching the user's pasteboard. `SAYLANE_TEST_SPEECH` is what gets "said".
@MainActor
enum TestScript {
    static let speech: String? = value("SAYLANE_TEST_SPEECH")
    static let front: String? = value("SAYLANE_TEST_FRONT")
    static var isActive: Bool { speech != nil }
    /// What would have been put on the pasteboard.
    static var pasteboard: [String] = []

    private static func value(_ name: String) -> String? {
        guard TestHome.isActive, let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    static var environment: VoiceInputEnvironment {
        VoiceInputEnvironment(frontmostBundleID: { front ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                              frontmostPID: { 4242 },
                              trace: { InputDiagnostics.record($0, $1) })
    }

    /// Everything a dictation needs is treated as present.
    static var readiness: Readiness {
        var ready = Readiness()
        ready.permissions.microphone = .granted
        ready.inputSource = .init(installedLocation: true, installed: true, enabled: true, selected: true)
        ready.models.speechReady = true
        ready.models.translationReady = true
        return ready
    }
}

/// Silence, in the shape the microphone delivers it.
@MainActor
final class ScriptedCapture: AudioCapturing {
    private var task: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?

    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error> {
        let pair = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        continuation = pair.continuation
        task = Task { @MainActor [weak self] in
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            while !Task.isCancelled, let self {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
                buffer.frameLength = 320
                memset(buffer.floatChannelData![0], 0, 320 * MemoryLayout<Float>.size)
                self.continuation?.yield(AudioFrame(buffer: buffer))
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return pair.stream
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }
}

/// A recognizer that hears the scripted sentence: half of it as a preview, all of it at the end.
@MainActor
final class ScriptedSpeech: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?
    private let text: String
    private var fed = 0

    init(_ text: String) { self.text = text }

    func begin(locale: Locale) async throws {}

    func feed(_ buffer: AVAudioPCMBuffer) throws {
        fed += 1
        if fed == 3 { onPartial?(SpeechHypothesis(volatileText: String(text.prefix(max(1, text.count / 2))))) }
    }

    func finish() async throws -> String { text }
    func cancel() async {}
}
