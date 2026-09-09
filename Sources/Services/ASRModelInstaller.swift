import CryptoKit
import Darwin
import Foundation

/// Runs away from MainActor; downloads only pinned, user-requested model assets.
actor ASRModelInstaller {
    typealias ProgressHandler = @Sendable (Int64, Int64, String) -> Void
    typealias Fetch = @Sendable (URL, @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse)
    private let root: URL
    private let fetch: Fetch?
    init(root: URL = ASRModelManifest.root, fetch: Fetch? = nil) {
        self.root = root
        self.fetch = fetch
    }

    func install(_ manifest: ASRModelManifest, progress: @escaping ProgressHandler) async throws {
        try manifest.validate()
        let fm = FileManager.default
        let destination = manifest.directory(root: root)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Also protect against a second application/diagnostic process downloading this variant.
        let lock = open(parent.appendingPathComponent(".download.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw ASRModelError.invalidDownload("无法创建下载锁") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ASRModelError.invalidDownload("此版本正在其他进程下载") }
        defer { flock(lock, LOCK_UN) }
        let capacity = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < manifest.totalBytes * 2 + 100_000_000 { throw ASRModelError.diskSpace }
        let staging = parent.appendingPathComponent("\(manifest.revision).partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var completed: Int64 = 0
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        for file in manifest.files {
            try Task.checkCancellation()
            let output = staging.appendingPathComponent(file.name)
            // Retry reuses fully downloaded AND reverified files, never trusts partial bytes.
            if try Self.verifyFile(output, file: file) {
                completed += file.size
                progress(completed, manifest.totalBytes, file.name)
                continue
            }
            let base = completed
            let report: @Sendable (Int64) -> Void = { bytes in
                progress(base + min(bytes, file.size), manifest.totalBytes, file.name)
            }
            let temporary: URL
            let response: URLResponse
            if let fetch {
                (temporary, response) = try await fetch(manifest.url(for: file), report)
            } else {
                (temporary, response) = try await ModelDownloadTransfer(report: report).run(manifest.url(for: file), configuration: config)
            }
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url?.scheme == "https" else { throw ASRModelError.invalidDownload(file.name) }
            try Task.checkCancellation()
            guard try Self.verifyFile(temporary, file: file) else { throw ASRModelError.checksum(file.name) }
            if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
            try fm.moveItem(at: temporary, to: output)
            completed += file.size
            progress(completed, manifest.totalBytes, file.name)
        }
        try Task.checkCancellation()
        try manifest.revision.write(to: staging.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        // Only publish a fully verified directory. Keep the previous install until this point.
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
    }

    func verify(_ manifest: ASRModelManifest) throws {
        try manifest.validate()
        guard manifest.isInstalled(root: root) else { throw ASRModelError.missing }
        for file in manifest.files {
            try Task.checkCancellation()
            guard try Self.verifyFile(manifest.directory(root: root).appendingPathComponent(file.name), file: file) else {
                throw ASRModelError.checksum(file.name)
            }
        }
    }

    nonisolated static func verifyFile(_ url: URL, file: ASRModelManifest.File) throws -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
              Int64(values?.fileSize ?? -1) == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}

/// Use a delegate-driven task: async download convenience APIs can suppress incremental
/// download callbacks. Continuation/task state is locked; result callbacks use URLSession's serial queue.
private final class ModelDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private var result: Result<(URL, URLResponse), Error>?
    private var lastReported: Int64 = 0

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func run(_ url: URL, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else { throw ASRModelError.invalidDownload("缺少响应") }
            // URLSession deletes its location after this callback. Own the verified input until install completes.
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent("saylane-model-" + UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: owned)
            result = .success((owned, response))
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let cancelled = self.cancelled
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        if let failure = error ?? (cancelled ? CancellationError() : nil) {
            if case .success(let value) = result { try? FileManager.default.removeItem(at: value.0) }
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume(with: result ?? .failure(ASRModelError.invalidDownload("下载未完成")))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten - lastReported >= 262_144 || totalBytesWritten == totalBytesExpectedToWrite {
            lastReported = totalBytesWritten
            report(totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
