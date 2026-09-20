import AVFoundation

enum AudioLevel {
    /// Detect digital silence only, across planar/interleaved PCM formats. This
    /// is deliberately not a voice-activity threshold: even a very quiet signal
    /// must be allowed through, and unsupported formats are never suppressed.
    static func hasSignal(in buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0 else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        for channel in buffers {
            guard let data = channel.mData else { continue }
            let bytes = Int(channel.mDataByteSize)
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: bytes / 4)
                if values.contains(where: { $0 != 0 }) { return true }
            case .pcmFormatFloat64:
                let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: bytes / 8)
                if values.contains(where: { $0 != 0 }) { return true }
            case .pcmFormatInt16:
                let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: bytes / 2)
                if values.contains(where: { $0 != 0 }) { return true }
            case .pcmFormatInt32:
                let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: bytes / 4)
                if values.contains(where: { $0 != 0 }) { return true }
            default: return true
            }
        }
        return false
    }

    static func normalized(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sumSquares: Float = 0
        for i in 0..<frames {
            let sample = samples[i]
            sumSquares += sample * sample
        }
        return normalized(rms: (sumSquares / Float(frames)).squareRoot())
    }

    static func normalized(rms: Float) -> Float {
        let clampedRms = max(rms, 1e-7)
        let db = 20 * log10(clampedRms)
        let floor: Float = -45
        let ceiling: Float = -10
        let clamped = max(floor, min(ceiling, db))
        let linear = (clamped - floor) / (ceiling - floor)
        return pow(linear, 0.7)
    }
}
