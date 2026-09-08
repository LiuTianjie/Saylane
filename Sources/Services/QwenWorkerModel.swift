import Foundation
import Darwin

struct QwenWorkerRequest: Codable {
    let audio: [Float]
    let language: String
}
struct QwenWorkerResponse: Codable {
    let text: String?
    let error: String?
    let memory: String
}

/// Private stdin/stdout transport: no server port, audio files or model downloads.
/// Only the runtime actor invokes exchange; cancellation may concurrently stop it.
private final class QwenWorkerConnection: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private let lock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false
    private var launched = false
    init(_ variant: SpeechModel) throws {
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--qwen-worker", variant.rawValue]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        launched = true
        // The child owns the other ends. EOF now reliably follows child exit.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
    deinit { stop() }
    func interrupt() {
        // Cancellation handlers can run on the UI caller's thread: signal only.
        // The lifetime owner reaps the process off MainActor after I/O drains.
        lock.lock(); defer { lock.unlock() }
        if launched, !stopped, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, launched else { return }
        stopped = true
        // This disposable helper has no user state to save. SIGKILL bounds release
        // even if Metal is hung; wait reaps it before the next model can start.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // waitUntilExit uses a thread-local RunLoop and can hang when Swift
        // actors create and release Process on different executor threads.
        exited.wait()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
    func exchange(_ request: QwenWorkerRequest?) throws -> QwenWorkerResponse {
        let watchdog = DispatchWorkItem { [weak self] in self?.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer { watchdog.cancel() }
        if let request {
            var data = try JSONEncoder().encode(request)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        var data = Data()
        while data.last != 10 {
            let chunk = try QwenWorkerIO.read(output.fileHandleForReading)
            guard !chunk.isEmpty else {
                throw NSError(domain: "QwenWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地识别进程已退出或超时，请重新选择模型后重试"])
            }
            data.append(chunk)
            guard data.count < 1_048_576 else { throw ASRModelError.manifest }
        }
        let response = try JSONDecoder().decode(QwenWorkerResponse.self, from: data)
        if let error = response.error {
            throw NSError(domain: "QwenWorker", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return response
    }
}

actor QwenWorkerModel: LoadedSpeechModel {
    private let connection: QwenWorkerConnection
    private(set) var memory = ""
    private init(_ connection: QwenWorkerConnection) { self.connection = connection }
    static func start(_ variant: SpeechModel) async throws -> QwenWorkerModel {
        let model = try QwenWorkerModel(QwenWorkerConnection(variant))
        try await model.load()
        return model
    }
    func diagnostics() -> String { "workerPID=\(connection.process.processIdentifier) \(memory)" }
    private func load() async throws {
        try Task.checkCancellation()
        let response = try await withTaskCancellationHandler {
            try connection.exchange(nil)
        } onCancel: { connection.interrupt() }
        try Task.checkCancellation()
        memory = response.memory
    }
    func transcribe(_ audio: [Float], language: String) async throws -> String {
        try Task.checkCancellation()
        let response = try await withTaskCancellationHandler {
            try connection.exchange(QwenWorkerRequest(audio: audio, language: language))
        } onCancel: { connection.interrupt() }
        try Task.checkCancellation()
        memory = response.memory
        return response.text ?? ""
    }
}

// POSIX read returns the available pipe bytes, not a requested-length buffered
// read that could wait for a full 64 KiB while both peers wait for each other.
enum QwenWorkerIO {
    static func read(_ handle: FileHandle) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
