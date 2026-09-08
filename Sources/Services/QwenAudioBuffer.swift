import AVFoundation

/// Bounded, session-owned mono 16 kHz PCM. Never retains the reusable microphone buffer.
final class QwenAudioBuffer {
    static let sampleRate = 16_000.0
    static let maxSamples = 30 * 16_000
    private(set) var samples: [Float] = []
    private let converter = BufferConverter()

    func append(_ input: AVAudioPCMBuffer) throws {
        guard input.frameLength > 0 else { return }
        guard input.format.sampleRate > 0, input.format.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false) else { throw SpeechEngineError.invalidFormat }
        let output = try converter.convertBuffer(input, to: format)
        let count = Int(output.frameLength)
        guard samples.count + count <= Self.maxSamples else { throw ASRModelError.tooLong }
        guard let channel = output.floatChannelData?[0] else { throw SpeechEngineError.invalidFormat }
        let values = UnsafeBufferPointer(start: channel, count: count)
        guard values.allSatisfy(\.isFinite) else { throw SpeechEngineError.invalidFormat }
        samples.append(contentsOf: values)
    }
}
