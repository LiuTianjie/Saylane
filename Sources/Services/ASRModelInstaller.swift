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
        guard lock >= 0 else { throw ASRModelError.invalidDownload(String(localized: "无法创建下载锁")) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ASRModelError.invalidDownload(String(localized: "此版本正在其他进程下载")) }
        defer { flock(lock, LOCK_UN) }
        let staging = parent.appendingPathComponent("\(manifest.revision).partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let capacity = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let additional = try Self.additionalBytesNeeded(manifest, staging: staging)
        if let capacity, capacity < additional { throw ASRModelError.diskSpace }
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
        // Publish only a fully verified directory. Replacement is one filesystem
        // operation, so a failed repair never deletes the working destination.
        try Self.publish(staging: staging, to: destination, fileManager: fm)
        // The requested revision is usable now. Stale cleanup is maintenance and
        // must not turn a successful install into a reported failure.
        do {
            try Self.removeSupersededRevisions(in: parent, keeping: manifest.revision)
        } catch {
            NSLog("Saylane: installed ASR revision %@ but could not remove every old revision: %@",
                  manifest.revision, error.localizedDescription)
        }
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

    /// Downloads are sequential. Existing, verified staging files need no more
    /// space. Downloads are sequential and the temporary download occupies the
    /// same bytes that will become the next staging file, so the peak on this
    /// volume is the remaining total plus a safety margin, not an extra copy of
    /// the largest file.
    nonisolated static func additionalBytesNeeded(_ manifest: ASRModelManifest, staging: URL) throws -> Int64 {
        var missing: [Int64] = []
        for file in manifest.files {
            if try !verifyFile(staging.appendingPathComponent(file.name), file: file) {
                missing.append(file.size)
            }
        }
        return missing.reduce(0, +) + 100_000_000
    }

    /// The staging and destination directories are siblings on the same volume.
    /// `replaceItemAt` gives repairs safe-save semantics; a failed replacement
    /// leaves the previous destination available. A first install is a same-volume
    /// rename through `moveItem`.
    nonisolated static func publish(staging: URL, to destination: URL,
                                    fileManager fm: FileManager = .default) throws {
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging,
                                     backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// A model id owns only 40-hex revision directories and their `.partial`
    /// siblings. Clean those after a successful atomic publish while preserving
    /// unrelated files and the current revision.
    nonisolated static func removeSupersededRevisions(in parent: URL, keeping revision: String,
                                                       fileManager fm: FileManager = .default) throws {
        let expression = try NSRegularExpression(pattern: "^[0-9a-f]{40}(?:\\.partial)?$")
        var firstFailure: Error?
        for url in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let name = url.lastPathComponent
            guard name != revision,
                  expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try fm.removeItem(at: url)
            }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
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
            guard let response = downloadTask.response else { throw ASRModelError.invalidDownload(String(localized: "缺少响应")) }
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
            continuation?.resume(with: result ?? .failure(ASRModelError.invalidDownload(String(localized: "下载未完成"))))
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
