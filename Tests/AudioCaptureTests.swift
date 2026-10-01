import AVFoundation
import Foundation

@main
struct AudioCaptureTests {
    @MainActor static func main() async throws {
        // Create the production callback from MainActor, as startStream does,
        // then invoke it from a worker with AVFoundation's reusable buffer.
        for _ in 0..<10 {
            let (stream, continuation) = AsyncThrowingStream<AudioFrame, Error>.makeStream()
            let tap = AudioCaptureService.makeTap(continuation: continuation)
            await Task.detached {
                dispatchPrecondition(condition: .notOnQueue(.main))
                let buffer = makeBuffer()
                for index in 1...8 {
                    buffer.floatChannelData![0][0] = Float(index)
                    tap(buffer, AVAudioTime(sampleTime: Int64(index * 64), atRate: 48000))
                }
                // The captured frames must not alias the engine's storage.
                buffer.floatChannelData![0][0] = -1
                continuation.finish()
                tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
            }.value

            var values: [Float] = []
            for try await frame in stream {
                precondition(frame.buffer.frameLength == 64)
                values.append(frame.buffer.floatChannelData![0][0])
            }
            precondition(values == (1...8).map(Float.init), "PCM must be owned, ordered, and stop after finish")
        }

        // A stalled consumer must get a bounded overflow error on the stream,
        // without crashing or touching MainActor from the callback.
        let (stream, continuation) = AsyncThrowingStream<AudioFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let tap = AudioCaptureService.makeTap(continuation: continuation)
        await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            let buffer = makeBuffer()
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
            tap(buffer, AVAudioTime(sampleTime: 64, atRate: 48000))
        }.value
        var frames = 0
        do {
            for try await _ in stream { frames += 1 }
            fatalError("overflow must fail the stream")
        } catch SessionFailure.audioOverflow {
            precondition(frames == 1)
        }
        print("PASS: background audio callbacks, owned PCM, repeated sessions, late callbacks and overflow (Swift 6)")
    }

    private static func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        buffer.frameLength = 64
        memset(buffer.floatChannelData![0], 0, 64 * MemoryLayout<Float>.size)
        return buffer
    }
}
