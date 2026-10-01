import AppKit
import SwiftUI
@preconcurrency import Translation

/// One translation engine for voice and screen, plus the only place that knows how
/// Apple's on-device model download works: a `.translationTask` needs a visible
/// SwiftUI host, so the provider owns a small window that appears only while a
/// download is required, instead of depending on the settings window being open.
@MainActor @Observable
final class TranslationProvider {
    let engine = TranslationEngine()
    private struct Pair: Equatable {
        let source: String
        let target: String
        init(_ source: Locale.Language, _ target: Locale.Language) {
            self.source = source.maximalIdentifier
            self.target = target.maximalIdentifier
        }
    }
    private(set) var configuration: TranslationSession.Configuration?
    private var readyPair: Pair?
    private var pendingPair: Pair?
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        var timeout: Task<Void, Never>?
    }
    private var waiters: [Waiter] = []
    private var host: TranslationDownloadWindow?
    private var generation = 0

    var isReady: Bool { engine.isReady }
    var needsDownload: Bool { engine.needsDownload }

    func reset() {
        generation += 1
        engine.reset()
        readyPair = nil
        pendingPair = nil
        configuration = nil
        resumeWaiters(with: TranslationEngineError.notReady)
        host?.orderOut(nil)
    }

    func enablePassthrough() {
        generation += 1
        engine.enablePassthrough()
        readyPair = nil
        pendingPair = nil
        configuration = nil
        host?.orderOut(nil)
        resumeWaiters(with: nil)
    }

    /// Prepare an installed pair. Throws `.unsupported`; leaves `needsDownload` set when a download is required.
    func prepareInstalled(source: Locale.Language, target: Locale.Language) async throws {
        let pair = Pair(source, target)
        if engine.isReady, !engine.isPassthrough, readyPair != pair { reset() }
        let token = generation
        try await engine.prepareInstalled(source: source, target: target)
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        if engine.isReady {
            readyPair = pair
            pendingPair = nil
            resumeWaiters(with: nil)
        }
    }

    /// Ask the system to download the pair. Shows the download host window.
    func requestDownload(source: Locale.Language, target: Locale.Language) {
        let pair = Pair(source, target)
        if pendingPair != nil, pendingPair != pair {
            generation += 1
            engine.reset()
            readyPair = nil
            resumeWaiters(with: TranslationEngineError.notReady)
        }
        pendingPair = pair
        configuration = TranslationSession.Configuration(source: source, target: target)
        presentHost()
    }

    /// Wait until the engine is usable, starting a download if needed.
    func ready(source: Locale.Language, target: Locale.Language, timeout: TimeInterval = 120) async throws {
        let pair = Pair(source, target)
        if engine.isReady, (engine.isPassthrough || readyPair == pair) { return }
        if engine.isReady || (pendingPair != nil && pendingPair != pair) { reset() }
        if !engine.needsDownload { try await prepareInstalled(source: source, target: target) }
        if engine.isReady { return }
        requestDownload(source: source, target: target)
        let token = generation
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, continuation: continuation, timeout: nil))
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.expireWaiter(id, error: TranslationEngineError.notReady)
                }
                if let index = waiters.firstIndex(where: { $0.id == id }) {
                    waiters[index].timeout = timer
                } else {
                    timer.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.expireWaiter(id, error: CancellationError()) }
        }
        guard token == generation, engine.isReady else { throw TranslationEngineError.notReady }
    }

    private func expireWaiter(_ id: UUID, error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeout?.cancel()
        waiter.continuation.resume(throwing: error)
        if waiters.isEmpty, !engine.isReady {
            generation += 1
            engine.reset()
            readyPair = nil
            pendingPair = nil
            configuration = nil
            host?.orderOut(nil)
        }
    }

    func handleSession(_ session: TranslationSession) async {
        let token = generation
        let pair = pendingPair
        do {
            try await engine.attach(session)
            guard token == generation, !Task.isCancelled else { return }
            readyPair = pair
            pendingPair = nil
            configuration = nil
            host?.orderOut(nil)
            resumeWaiters(with: nil)
        } catch {
            guard token == generation else { return }
            engine.reset()
            readyPair = nil
            pendingPair = nil
            configuration = nil
            host?.orderOut(nil)
            resumeWaiters(with: error)
        }
    }

    func translate(_ text: String) async throws -> String { try await engine.translate(text) }
    func translateBatch(_ texts: [String]) async throws -> [String] { try await engine.translateBatch(texts) }

    private func resumeWaiters(with error: Error?) {
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.timeout?.cancel()
            if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
        }
    }

    private func presentHost() {
        let window = host ?? TranslationDownloadWindow(provider: self)
        host = window
        window.center()
        window.orderFrontRegardless()
    }

    fileprivate func cancelDownload() {
        generation += 1
        engine.reset()
        readyPair = nil
        pendingPair = nil
        configuration = nil
        resumeWaiters(with: CancellationError())
        host?.orderOut(nil)
    }
}

/// Small non-activating window that hosts the `.translationTask` modifier while a
/// model download is pending. Apple's approval sheet attaches to it.
@MainActor
final class TranslationDownloadWindow: NSPanel {
    private weak var provider: TranslationProvider?

    init(provider: TranslationProvider) {
        self.provider = provider
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = String(localized: "下载翻译模型")
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: TranslationDownloadView(provider: provider))
    }

    override func close() {
        provider?.cancelDownload()
        super.close()
    }
}

private struct TranslationDownloadView: View {
    @Bindable var provider: TranslationProvider
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "正在准备翻译模型"), systemImage: "arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(String(localized: "系统会询问是否下载这对语言的离线翻译模型。下载完成后这个窗口会自动关闭。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView().controlSize(.small)
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .translationTask(provider.configuration) { session in
            await provider.handleSession(session)
        }
    }
}
