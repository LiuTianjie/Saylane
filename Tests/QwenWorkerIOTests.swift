import Foundation

@main struct QwenWorkerIOTests {
    static func main() throws {
        let pipe = Pipe()
        let completed = DispatchSemaphore(value: 0)
        let bytes = Data("ready\n".utf8)
        DispatchQueue.global().async {
            do {
                let actual = try QwenWorkerIO.read(pipe.fileHandleForReading)
                precondition(actual == bytes)
                completed.signal()
            } catch { fatalError("pipe read: \(error)") }
        }
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        // Keep writer open: a short message must not wait for 64 KiB or EOF.
        precondition(completed.wait(timeout: .now() + 2) == .success)
        try pipe.fileHandleForWriting.close()
        let eof = try QwenWorkerIO.read(pipe.fileHandleForReading)
        precondition(eof.isEmpty)
        print("Qwen worker IPC: short message without EOF and closed-parent EOF passed")
    }
}
