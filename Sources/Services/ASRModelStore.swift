import Foundation
import Observation

@MainActor @Observable final class ASRModelStore {
    private(set) var installed: Set<SpeechModel> = []
    private(set) var downloading: SpeechModel?
    private(set) var progress = 0.0
    private(set) var activity = ""
    private var downloadTask: Task<Void, Error>?
    private var downloadID: UUID?
    var isDownloading: Bool { downloading != nil }

    init() { refresh() }

    func refresh() {
        installed = Set(SpeechModel.allCases.filter { $0.isQwen && ((try? $0.manifest().isInstalled()) == true) })
    }

    func download(_ variant: SpeechModel) async throws {
        guard variant.isQwen, !isDownloading else { return }
        let manifest = try variant.manifest()
        let token = UUID()
        downloadID = token
        downloading = variant
        progress = 0
        activity = "正在连接下载源…"
        let task = Task {
            try await ASRModelInstaller().install(manifest) { [weak self] completed, total, file in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadID == token else { return }
                    self.progress = Double(completed) / Double(total)
                    self.activity = "\(Int(completed / 1_000_000)) / \(Int(total / 1_000_000)) MB · \(file)"
                }
            }
        }
        downloadTask = task
        defer {
            downloadID = nil
            downloading = nil
            downloadTask = nil
            refresh()
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        activity = "正在取消…"
    }

    func remove(_ variant: SpeechModel) throws {
        guard variant.isQwen, !isDownloading else { return }
        let manifest = try variant.manifest()
        // Removes this variant's weights and incomplete downloads only; never the entire app directory.
        let directory = manifest.directory().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        refresh()
    }
}
