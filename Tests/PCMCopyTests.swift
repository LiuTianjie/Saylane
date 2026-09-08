import AVFoundation

@main
struct PCMCopyTests {
    static func main() {
        for common in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let format = AVAudioFormat(commonFormat: common, sampleRate: 48000, channels: 2, interleaved: interleaved)!
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
                input.frameLength = 32
                let original = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
                for item in original { memset(item.mData!, 0x32, Int(item.mDataByteSize)) }
                guard let copy = PCMCopy.copy(input) else { fatalError("copy failed") }
                let copied = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                precondition(copy.frameLength == input.frameLength)
                for i in original.indices {
                    precondition(original[i].mData != copied[i].mData)
                    precondition(memcmp(original[i].mData!, copied[i].mData!, Int(original[i].mDataByteSize)) == 0)
                    memset(original[i].mData!, 0, Int(original[i].mDataByteSize))
                    precondition(copied[i].mData!.load(as: UInt8.self) == 0x32)
                }
            }
        }
        print("PASS: six PCM formats/layouts preserve independent buffer data")
    }
}
