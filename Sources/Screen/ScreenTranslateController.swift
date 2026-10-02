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
    var fullText = ""
}

/// Screen translation: selection → capture → analyze → translate → compose → pin.
/// The picture work is `ScreenPipeline`; this object owns the windows' state.
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
    var polish: (@Sendable (String, String, String, String, String) async throws -> String)?

    private let pinModel = ScreenPinModel()
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
        translationCache = ScreenTranslationCache()
        pinModel.fullText = ""
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
            if pinPanel?.closeTranslationDetail() == true { return }
            cancel()
        case .toggleOverlay:
            guard pinPanel?.hasTranslationDetail != true else { return }
            toggleOverlay()
        case .copy:
            guard pinPanel?.hasTranslationDetail != true else { return }
            _ = copyImage()
        case .retry:
            guard isPinVisible, pinPanel?.hasTranslationDetail != true else { return }
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
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.writeObjects([image])
        if ok { cancel() }
        return ok
    }

    private func completeSelection(rect: CGRect, screen: NSScreen) {
        guard isSelecting else { return }
        tearDownSelection()
        let token = generation
        onDirectionChanged?(direction)
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
        await present(captured: image, at: CGRect(origin: CGPoint(x: 40, y: 40), size: image.size))
        return (pinPanel?.snapshot(), pinModel.status)
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
            let composition = await show(analysis, translations: translations, token: token)
            guard token == generation, !Task.isCancelled else { return }
            if let polish {
                setChromeStatus(String(localized: "正在润色"), working: true)
                let sourceName = direction.source.displayName
                let targetName = direction.target.displayName
                // Bound concurrent network work, and publish one coherent result
                // instead of redrawing the picture after every polished block.
                for start in stride(from: 0, to: wanted.count, by: 4) {
                    guard token == generation, !Task.isCancelled else { return }
                    let inputs = wanted[start..<min(start + 4, wanted.count)].map { index in
                        (index, analysis.blocks[index].original, translations[index] ?? "", Self.context(for: index, in: analysis.blocks))
                    }
                    let tasks = inputs.map { index, original, translated, context in
                        Task { @MainActor () -> (Int, String?) in
                            (index, try? await polish(original, translated, sourceName, targetName, context))
                        }
                    }
                    var results: [(Int, String?)] = []
                    for task in tasks { results.append(await task.value) }
                    guard token == generation, !Task.isCancelled else { return }
                    for (index, result) in results {
                        if let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translations[index] = result }
                    }
                }
                _ = await show(analysis, translations: translations, token: token)
                guard token == generation, !Task.isCancelled else { return }
            }
            setChromeStatus("", working: false)
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
        // What is on the picture, in reading order, for "full text".
        pinModel.fullText = composition.placed.map { composition.blocks[$0.index].translation }.joined(separator: "\n")
        refreshDisplayed()
        return composition
    }

    /// The blocks around one, nearest first: what a proofreading model gets to see of the page.
    static func context(for index: Int, in blocks: [TextBlock]) -> String {
        guard blocks.indices.contains(index) else { return "" }
        let anchor = blocks[index].rect
        let neighbors = blocks.indices.filter { $0 != index }.sorted { lhs, rhs in
            func distance(_ i: Int) -> CGFloat {
                let box = blocks[i].rect
                let gap = max(0, max(anchor.minX - box.maxX, box.minX - anchor.maxX))
                return gap * 3 + abs(anchor.midY - box.midY)
            }
            let a = distance(lhs), b = distance(rhs)
            return a == b ? lhs < rhs : a < b
        }
        var parts: [String] = []
        var bytes = 0
        for i in neighbors.prefix(12) {
            let text = String(blocks[i].original.prefix(400))
            guard bytes + text.utf8.count + 2 <= 4_000 else { continue }
            parts.append(text)
            bytes += text.utf8.count + 2
        }
        return parts.joined(separator: "\n\n")
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
        if translatedImage == nil { pinModel.fullText = "" }
        pinPanel?.show(translated: translatedImage, overlayEnabled: overlayEnabled)
        pinPanel?.setWorking(pinModel.isWorking)
    }

    private func setChromeStatus(_ text: String, working: Bool) {
        pinModel.status = text
        pinModel.isWorking = working
        pinPanel?.setWorking(working)
        pinPanel?.refreshChrome()
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
