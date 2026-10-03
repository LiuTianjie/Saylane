import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class ScreenPinModel {
    var original = NSImage()
    var overlayEnabled = true
    var directionTitle = ""
    var status = ""
    var isWorking = false
}

/// Screen translation: selection → capture → analyze → translate → compose → pin.
/// The picture work is `ScreenPipeline`; this object owns the windows' state.
/// With precise translation on, a language model reads the whole screen while the
/// quick translation is made and shown; its answer is set over the quick one.
/// Windows live in `ScreenSelectionPanel` / `ScreenPinPanel`; this object owns
/// state and the pipeline only.
@MainActor
final class ScreenTranslateController {
    private(set) var isSelecting = false
    private(set) var isPinVisible = false
    var isActive: Bool { isSelecting || isPinVisible }

    var overlayEnabled = true
    /// Block pointer input to other applications while a pin is visible (off by default).
    var freezesScreen = false
    /// True when a global key router already delivers Esc/⌘C/Tab for us.
    var keysHandledGlobally: () -> Bool = { false }
    private(set) var direction = TranslationDirection(source: .zhHans, target: .en)
    var onError: ((String) -> Void)?
    var onPinVisibilityChanged: ((Bool) -> Void)?
    var onScreenActiveChanged: ((Bool) -> Void)?
    var onDirectionChanged: ((TranslationDirection) -> Void)?
    /// The whole-screen translation by a language model, when the user has switched it on.
    var precise: ScreenPreciseTranslator?

    private let pinModel = ScreenPinModel()
    /// Where "Copy" puts the picture. The design preview uses a pasteboard of its own.
    var pasteboard = NSPasteboard.general
    /// Own provider: the screen direction is independent of the voice direction.
    let translation = TranslationProvider()
    private var preparedDirection: TranslationDirection?
    private var selectionPanels: [ScreenSelectionPanel] = []
    private var pinPanel: ScreenPinPanel?
    private var eventMonitor: Any?
    private var work: Task<Void, Never>?
    /// What was read off the captured picture, and for which direction.
    private var analysis: ScreenPipeline.Analysis?
    private var analyzedDirection: TranslationDirection?
    private var translatedImage: NSImage?
    private var originalImage = NSImage()
    private var generation = 0
    private var translationCache = ScreenTranslationCache()
    private var pairA: AppLanguage = .zhHans
    private var pairB: AppLanguage = .en
    /// The application the capture was taken from: context for the precise translation.
    private var capturedApp: String?

    func beginSelection(a: AppLanguage, b: AppLanguage, last: TranslationDirection?, preserveKeyboardFocus: Bool = false) {
        cancel()
        pairA = a
        pairB = b
        direction = ScreenTranslate.screenMode(current: last, a: a, b: b)
        overlayEnabled = true
        isSelecting = true
        onScreenActiveChanged?(true)
        InputDiagnostics.record("screen-select", direction.id)
        for screen in NSScreen.screens {
            let panel = ScreenSelectionPanel(screen: screen, title: direction.compactTitle)
            panel.onDragEnded = { [weak self] rect in
                self?.completeSelection(rect: rect, screen: screen)
            }
            panel.onCancel = { [weak self] in self?.cancel() }
            selectionPanels.append(panel)
            panel.orderFrontRegardless()
            readRegions(for: panel, screen: screen)
        }
        // Keep keyboard focus in the original app whenever the global router can
        // deliver Esc; only activate when that is the only way to receive keys.
        if !preserveKeyboardFocus && !keysHandledGlobally() {
            NSApp.activate(ignoringOtherApps: true)
            selectionPanels.first?.makeKey()
        }
        installEventMonitor()
    }

    func cancel() {
        work?.cancel()
        work = nil
        generation += 1
        preparedDirection = nil
        tearDownSelection()
        pinPanel?.orderOut(nil)
        pinPanel = nil
        let wasVisible = isPinVisible
        isPinVisible = false
        if wasVisible { onPinVisibilityChanged?(false) }
        onScreenActiveChanged?(false)
        analysis = nil
        analyzedDirection = nil
        translatedImage = nil
        capturedApp = nil
        translationCache = ScreenTranslationCache()
        removeEventMonitor()
    }

    func cycleDirection(a: AppLanguage, b: AppLanguage) {
        guard isSelecting || isPinVisible else { return }
        pairA = a
        pairB = b
        direction = ScreenTranslate.cycled(current: direction, a: a, b: b)
        onDirectionChanged?(direction)
        pinModel.directionTitle = direction.compactTitle
        InputDiagnostics.record("screen-direction", direction.id)
        if isSelecting {
            for panel in selectionPanels { panel.setTitle(direction.compactTitle) }
            return
        }
        restartTranslation()
    }

    func toggleOverlay() {
        guard isPinVisible else { return }
        overlayEnabled.toggle()
        refreshDisplayed()
    }

    /// Keys routed from the global tap while a pin (or a selection) is on screen.
    func handlePinKey(_ key: ScreenPinKey, a: AppLanguage, b: AppLanguage) {
        switch key {
        case .close:
            cancel()
        case .toggleOverlay:
            toggleOverlay()
        case .copy:
            _ = copyImage()
        case .retry:
            guard isPinVisible else { return }
            restartTranslation()
        case .cycleDirection:
            cycleDirection(a: a, b: b)
        }
    }

    @discardableResult
    func copyImage() -> Bool {
        guard isPinVisible else { return false }
        let image = overlayEnabled ? (translatedImage ?? originalImage) : originalImage
        guard image.size.width > 0 else { return false }
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects([image])
        InputDiagnostics.record("screen-copy", "\(overlayEnabled && translatedImage != nil ? "translation" : "capture") \(ok ? "copied" : "failed")")
        if ok { cancel() }
        return ok
    }

    private func completeSelection(rect: CGRect, screen: NSScreen) {
        guard isSelecting else { return }
        tearDownSelection()
        let token = generation
        onDirectionChanged?(direction)
        capturedApp = ScreenWindowProbe.owner(at: CGPoint(x: rect.midX, y: rect.midY),
                                              excludingPID: ProcessInfo.processInfo.processIdentifier)
        let display = ScreenCaptureService.Display(screen)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await ScreenCaptureService.capture(rectInScreen: rect, display: display)
                guard token == self.generation, !Task.isCancelled else { return }
                await self.present(captured: image, at: rect)
            } catch is CancellationError {
            } catch {
                guard token == self.generation else { return }
                self.onError?(error.localizedDescription)
                self.setChromeStatus(error.localizedDescription, working: false)
            }
        }
    }

    /// Pin a captured picture where it was taken and translate it in place.
    func present(captured image: NSImage, at rect: CGRect) async {
        originalImage = image
        analysis = nil
        analyzedDirection = nil
        translatedImage = nil
        showPin(image: image, at: rect)
        await translate()
    }

    #if DEBUG
    /// For the design preview: a picture file through the same path as a capture, in a given direction.
    func preview(_ image: NSImage, direction: TranslationDirection) async -> (pin: NSBitmapImageRep?, status: String) {
        self.direction = direction
        // SAYLANE_PRECISE_ANSWERS names a file that stands in for the language model: a table of
        // source text → translation (null: keep), or any other text, returned as the model's whole answer.
        if let path = ProcessInfo.processInfo.environment["SAYLANE_PRECISE_ANSWERS"],
           let data = FileManager.default.contents(atPath: path) {
            if let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                precise = ScreenPreciseTranslator(transport: ScreenPreciseTranslator.canned(table.mapValues { $0 as? String }))
            } else {
                let answer = String(decoding: data, as: UTF8.self)
                precise = ScreenPreciseTranslator(transport: { _, _ in answer })
            }
            onError = { print("notice: \($0)") }
        }
        await present(captured: image, at: CGRect(origin: CGPoint(x: 40, y: 40), size: image.size))
        let pin = pinPanel?.snapshot()
        // The toolbar as it looks, then its Copy button the way a click runs it — on a pasteboard of our own.
        if let toolbar = pinPanel?.chromeSnapshot(), let path = ProcessInfo.processInfo.environment["SAYLANE_TOOLBAR_SNAPSHOT"] {
            try? toolbar.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("local.saylane.preview.\(ProcessInfo.processInfo.processIdentifier)"))
        pinPanel?.onCopy?()
        print("copy button → types \(pasteboard.types?.map(\.rawValue) ?? []), text: \(pasteboard.string(forType: .string) ?? "none"), pin still open: \(isPinVisible)")
        pasteboard.releaseGlobally()
        return (pin, pinModel.status)
    }
    #endif

    /// A change of direction or a manual retry supersedes whatever is in flight.
    private func restartTranslation() {
        work?.cancel()
        work = nil
        generation += 1
        if analyzedDirection != direction {
            // Which lines are text to translate depends on both languages: read the picture again.
            translatedImage = nil
            refreshDisplayed()
            InputDiagnostics.record("screen-reocr", direction.id)
        }
        work = Task { [weak self] in await self?.translate() }
    }

    private func translate() async {
        let token = generation
        let direction = self.direction
        pinModel.directionTitle = direction.compactTitle
        do {
            async let prepared: Void = prepareEngine()
            var analysis = self.analysis
            if analysis == nil || analyzedDirection != direction {
                setChromeStatus(String(localized: "正在识别"), working: true)
                guard let picture = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      originalImage.size.width > 0 else {
                    _ = try? await prepared
                    setChromeStatus(String(localized: "没有识别到文字"), working: false)
                    return
                }
                let scale = CGFloat(picture.width) / originalImage.size.width
                // Reading and measuring the picture takes a few tenths of a second on every core: not on the main actor.
                analysis = try await Task.detached(priority: .userInitiated) {
                    try ScreenPipeline.analyze(picture, scale: scale, source: direction.source, target: direction.target)
                }.value
                guard token == generation, !Task.isCancelled else { _ = try? await prepared; return }
                self.analysis = analysis
                analyzedDirection = direction
            }
            guard let analysis, analysis.recognized > 0 else {
                _ = try? await prepared
                guard token == generation else { return }
                refreshDisplayed()
                setChromeStatus(String(localized: "没有识别到文字"), working: false)
                return
            }
            let wanted = analysis.blocks.indices.filter { analysis.blocks[$0].translate }
            // The language model reads the whole screen while the quick translation is made.
            // Same language on both sides is a passthrough: there is nothing to ask.
            let model = wanted.isEmpty || direction.source == direction.target ? nil : precise
            let app = capturedApp
            async let refined = model?.translate(
                PreciseTranslation.requests(analysis.blocks, scale: analysis.scale, target: direction.target),
                source: direction.source, target: direction.target, app: app)
            try await prepared
            guard token == generation, !Task.isCancelled else { return }
            guard !wanted.isEmpty else {
                // Text, but nothing to translate: code, numbers, or already the target language.
                refreshDisplayed()
                setChromeStatus("", working: false)
                return
            }
            setChromeStatus(String(localized: "正在翻译"), working: true)
            let originals = wanted.map { analysis.blocks[$0].original }
            let missing = translationCache.missing(originals, direction: direction.id)
            let fresh = missing.isEmpty ? [] : try await translation.translateBatch(missing)
            guard token == generation, !Task.isCancelled else { return }
            for (text, translated) in zip(missing, fresh) {
                translationCache.store(text, translation: translated, direction: direction.id)
            }
            let freshByText = Dictionary(zip(missing, fresh), uniquingKeysWith: { first, _ in first })
            var translations: [Int: String] = [:]
            for (index, original) in zip(wanted, originals) {
                translations[index] = freshByText[original] ?? translationCache.value(original, direction: direction.id) ?? original
            }
            // The quick picture first: nothing waits for the model.
            var composition = await show(analysis, translations: translations, token: token)
            guard token == generation, !Task.isCancelled else { return }
            var notice: String?
            if model != nil {
                setChromeStatus(String(localized: "正在精翻"), working: true)
                if let outcome = await refined {
                    guard token == generation, !Task.isCancelled else { return }
                    let accepted = outcome.accepted
                    if !accepted.isEmpty {
                        // Once more, with the model's words where it gave good ones and the original pixels where it said keep.
                        composition = await show(analysis, translations: PreciseTranslation.merge(translations, accepted), token: token) ?? composition
                        guard token == generation, !Task.isCancelled else { return }
                    }
                    notice = outcome.failure.map { Self.notice(for: $0, partial: !accepted.isEmpty) }
                    InputDiagnostics.record("screen-precise", String(format: "requests=%d translated=%d kept=%d rejected=%d long=%d seconds=%.1f %@",
                        outcome.requests, accepted.translations.count, accepted.kept.count, accepted.rejected, accepted.long, outcome.seconds,
                        outcome.failure.map { "failed=\($0.name)" } ?? "ok"))
                }
            }
            setChromeStatus("", working: false)
            // The quick picture stays; say once why the precise one did not come.
            if let notice { onError?(notice) }
            let seconds = analysis.seconds
            InputDiagnostics.record("screen-translated", String(format: "blocks=%d placed=%d shrunk=%d cut=%d ocr=%.2f measure=%.2f",
                analysis.blocks.count, composition?.placed.count ?? 0, composition?.shrunk ?? 0, composition?.cut ?? 0,
                seconds.recognize, seconds.measure))
        } catch is CancellationError {
        } catch {
            guard token == generation else { return }
            setChromeStatus(error.localizedDescription, working: false)
            onError?(error.localizedDescription)
        }
    }

    /// Fit, erase and draw; then show the picture. Off the main actor: a few hundredths of a second.
    private func show(_ analysis: ScreenPipeline.Analysis, translations: [Int: String], token: Int) async -> ScreenPipeline.Composition? {
        let composition = await Task.detached(priority: .userInitiated) {
            ScreenPipeline.compose(analysis, translations: translations)
        }.value
        guard token == generation, !Task.isCancelled, let picture = composition.pixels.cgImage() else { return nil }
        translatedImage = NSImage(cgImage: picture, size: originalImage.size)
        refreshDisplayed()
        return composition
    }

    /// A few words for when the precise translation did not arrive, or only some of it did.
    static func notice(for failure: ScreenPreciseTranslator.Failure, partial: Bool) -> String {
        if partial { return String(localized: "精翻只完成了一部分，其余保留本机翻译。") }
        switch failure {
        case .timeout: return String(localized: "精翻超时，已保留本机翻译。")
        case .unusable: return String(localized: "精翻的回答无法使用，已保留本机翻译。")
        case .endpoint(let reason): return String(localized: "精翻未完成，已保留本机翻译：\(reason)")
        }
    }

    private func prepareEngine() async throws {
        if preparedDirection == direction, translation.isReady { return }
        translation.reset()
        preparedDirection = nil
        if direction.source == direction.target {
            translation.enablePassthrough()
            preparedDirection = direction
            pinPanel?.refreshChrome()
            return
        }
        let source = direction.source.translationLanguage
        let target = direction.target.translationLanguage
        try await translation.prepareInstalled(source: source, target: target)
        if translation.needsDownload {
            setChromeStatus(String(localized: "正在下载翻译模型"), working: true)
            try await translation.ready(source: source, target: target)
        }
        preparedDirection = direction
    }

    private func showPin(image: NSImage, at rect: CGRect) {
        pinModel.original = image
        pinModel.overlayEnabled = overlayEnabled
        pinModel.directionTitle = direction.compactTitle
        pinModel.status = ""
        let panel = pinPanel ?? ScreenPinPanel(model: pinModel)
        panel.freezesScreen = freezesScreen
        panel.onToggleOverlay = { [weak self] in self?.toggleOverlay() }
        panel.onCopy = { [weak self] in _ = self?.copyImage() }
        panel.onClose = { [weak self] in self?.cancel() }
        panel.onCycle = { [weak self] in
            guard let self else { return }
            self.cycleDirection(a: self.pairA, b: self.pairB)
        }
        pinPanel = panel
        panel.present(source: image, at: rect)
        panel.setWorking(true)
        isPinVisible = true
        onPinVisibilityChanged?(true)
        onScreenActiveChanged?(true)
        installEventMonitor()
    }

    private func refreshDisplayed() {
        pinModel.overlayEnabled = overlayEnabled
        pinPanel?.show(translated: translatedImage, overlayEnabled: overlayEnabled)
        pinPanel?.setWorking(pinModel.isWorking)
    }

    private func setChromeStatus(_ text: String, working: Bool) {
        pinModel.status = text
        pinModel.isWorking = working
        pinPanel?.setWorking(working)
        pinPanel?.refreshChrome()
    }

    /// Reads the screen under the overlay once, so hover can offer the region under the
    /// pointer and not only its window. Until it is ready, hover offers windows.
    private func readRegions(for panel: ScreenSelectionPanel, screen: NSScreen) {
        let display = ScreenCaptureService.Display(screen)
        let token = generation
        Task { [weak self, weak panel] in
            let started = Date()
            guard let image = try? await ScreenCaptureService.captureImage(rectInScreen: display.frame, display: display) else { return }
            let map = await Task.detached(priority: .userInitiated) {
                ScreenRegionMap(image: image, frame: display.frame)
            }.value
            guard let self, let panel, let map, token == self.generation, self.isSelecting else { return }
            panel.setRegionMap(map)
            InputDiagnostics.record("screen-regions", String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000))
        }
    }

    private func tearDownSelection() {
        isSelecting = false
        for panel in selectionPanels { panel.orderOut(nil) }
        selectionPanels = []
    }

    /// Keys while one of our panels is key: Esc during selection (also delivered by
    /// the global router when it filters), and the pin's own keys once it was clicked.
    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.isSelecting, self.keysHandledGlobally() { return event }
            guard let converted = InputEvent(event, source: .settingsWindow, timestamp: 0),
                  let key = GestureArbiter.localPinKey(converted, selecting: self.isSelecting) else { return event }
            self.handlePinKey(key, a: self.pairA, b: self.pairB)
            return nil
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
