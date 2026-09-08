import Darwin
@preconcurrency import AVFoundation

final class BufferConverter: @unchecked Sendable {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw ConversionError.failedToCreateBuffer
        }

        final class Flag: @unchecked Sendable { var consumed = false }
        let flag = Flag()
        var nsError: NSError?
        let status = converter.convert(to: output, error: &nsError) { _, statusPtr in
            defer { flag.consumed = true }
            statusPtr.pointee = flag.consumed ? .noDataNow : .haveData
            return flag.consumed ? nil : buffer
        }
        guard status != .error else { throw ConversionError.conversionFailed(nsError) }
        return output
    }
}

enum PCMCopy {
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        output.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            let bytes = Int(source[index].mDataByteSize)
            guard bytes <= Int(destination[index].mDataByteSize) else { return nil }
            if bytes > 0 {
                guard let src = source[index].mData, let dst = destination[index].mData else { return nil }
                memcpy(dst, src, bytes)
            }
        }
        return output
    }
}
