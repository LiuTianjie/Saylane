import AVFoundation

@main struct AudioSignalTests {
    static func main() {
        var cases = 0
        for format in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let pcm = AVAudioFormat(commonFormat: format, sampleRate: 48000, channels: 2, interleaved: interleaved)!
                let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 32)!
                buffer.frameLength = 16
                let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for channel in buffers { memset(channel.mData!, 0, Int(channel.mDataByteSize)) }
                precondition(!AudioLevel.hasSignal(in: buffer))
                let final = buffers[buffers.count - 1]
                switch format {
                case .pcmFormatFloat32:
                    let samples = final.mData!.assumingMemoryBound(to: Float.self)
                    samples[Int(final.mDataByteSize) / 4 - 1] = -0.0
                    precondition(!AudioLevel.hasSignal(in: buffer))
                    samples[Int(final.mDataByteSize) / 4 - 1] = 0.0000001
                case .pcmFormatFloat64:
                    final.mData!.assumingMemoryBound(to: Double.self)[Int(final.mDataByteSize) / 8 - 1] = 0.0000001
                case .pcmFormatInt16:
                    final.mData!.assumingMemoryBound(to: Int16.self)[Int(final.mDataByteSize) / 2 - 1] = 1
                case .pcmFormatInt32:
                    final.mData!.assumingMemoryBound(to: Int32.self)[Int(final.mDataByteSize) / 4 - 1] = 1
                default: fatalError()
                }
                precondition(AudioLevel.hasSignal(in: buffer), "quiet/right-channel speech was rejected")
                buffer.frameLength = 0
                precondition(!AudioLevel.hasSignal(in: buffer))
                cases += 1
            }
        }
        print("PASS: digital silence and very quiet signals in \(cases) PCM formats/layouts")
    }
}
