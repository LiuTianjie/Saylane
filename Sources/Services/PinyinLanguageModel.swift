import CryptoKit
import Foundation
import Observation

/// The optional whole-sentence language model for pinyin. It is not shipped:
/// the user downloads it from the settings (409 MB, from the project that
/// publishes it), it is checked against a pinned hash, and it is put next to
/// the pinyin user dictionary, where the input method's engine finds it.
/// On 60 everyday sentences typed as one string of pinyin the engine gets 35
/// right without it and 44 with it.
@MainActor @Observable
final class PinyinLanguageModel {
    enum State: Equatable {
        case absent
        case downloading(received: Int64)
        case verifying
        case installed
        case failed(String)
        var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    /// Wanxiang LTS grammar for Simplified Chinese, amzxyz/RIME-LMDG, CC BY 4.0.
    static let fileName = "wanxiang-lts-zh-hans.gram"
    static let source = URL(string: "https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram")!
    static let sha256 = "873cbbb359fcf4df8b200183683ddc8be7b321eac4c864f8d2c7fc3136d4279f"
    static let bytes: Int64 = 409_412_652

    private(set) var state: State = .absent
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Installed or removed: the input method should load the fitting schema.
    @ObservationIgnored var onChanged: (() -> Void)?

    init(directory: URL = AppDirectories.rime) {
        self.directory = directory
        refresh()
    }

    var file: URL { directory.appendingPathComponent(Self.fileName) }
    var isInstalled: Bool { state == .installed }

    func refresh() {
        if case .downloading = state { return }
        if state == .verifying { return }
        state = FileManager.default.fileExists(atPath: file.path) ? .installed : .absent
    }

    func download() {
        guard task == nil, state != .installed else { return }
        state = .downloading(received: 0)
        let destination = file
        task = Task { [weak self] in
            do {
                let transfer = ModelDownloadTransfer { received in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(received: received) }
                    }
                }
                let (downloaded, _) = try await transfer.run(Self.source, configuration: .ephemeral)
                defer { try? FileManager.default.removeItem(at: downloaded) }
                self?.state = .verifying
                let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: downloaded) }.value
                guard digest == Self.sha256 else {
                    throw Failure.message(String(localized: "下载的文件校验不一致，可能是发布方更新了模型。"))
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: downloaded, to: destination)
                self?.finish(.installed)
            } catch is CancellationError {
                self?.finish(.absent)
            } catch {
                let text = (error as? Failure)?.text ?? error.localizedDescription
                self?.finish(.failed(text))
            }
        }
    }

    func cancel() { task?.cancel() }

    func remove() {
        guard task == nil else { return }
        try? FileManager.default.removeItem(at: file)
        finish(FileManager.default.fileExists(atPath: file.path) ? .installed : .absent)
    }

    private func finish(_ next: State) {
        task = nil
        state = next
        onChanged?()
    }

    private enum Failure: Error {
        case message(String)
        var text: String { if case .message(let text) = self { return text }; return "" }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
