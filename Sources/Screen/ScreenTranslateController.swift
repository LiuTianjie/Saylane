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

/// Screen translation: selection → capture → OCR → group → translate → pin.
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
    /// Font-weight detection on the captured image.
    var fontWeightDetection = true
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
    private var lines: [ScreenOCRLine] = []
    private var paragraphs: [ScreenParagraph] = []
    private var recognizedSource: AppLanguage?
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
        lines = []
        paragraphs = []
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
        restartTranslation(reRecognize: recognizedSource != direction.source)
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
            restartTranslation(reRecognize: false)
        case .cycleDirection:
            cycleDirection(a: a, b: b)
        }
    }

    @discardableResult
    func copyImage() -> Bool {
        guard isPinVisible else { return false }
        let image: NSImage
        if overlayEnabled {
            image = renderedOverlay()
        } else {
            image = originalImage
        }
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
                self.originalImage = image
                self.lines = []
                self.paragraphs = []
                self.showPin(image: image, at: rect)
                self.setChromeStatus(String(localized: "正在识别"), working: true)
                let languages = ScreenTranslate.ocrLanguageHints(
                    source: self.direction.source,
                    target: self.direction.target
                )
                async let recognized = ScreenOCRService.recognize(image, languages: languages)
                async let prepared: Void = self.prepareEngine()
                let lines = try await ScreenFontWeightService.annotate(try await recognized, image: image, enabled: self.fontWeightDetection)
                guard token == self.generation, !Task.isCancelled else { return }
                self.lines = lines
                self.recognizedSource = self.direction.source
                if lines.isEmpty {
                    self.setChromeStatus(String(localized: "没有识别到文字"), working: false)
                    return
                }
                do { try await prepared } catch { throw error }
                guard token == self.generation, !Task.isCancelled else { return }
                await self.retranslate()
            } catch is CancellationError {
            } catch {
                guard token == self.generation else { return }
                self.onError?(error.localizedDescription)
                self.setChromeStatus(error.localizedDescription, working: false)
            }
        }
    }

    /// Direction changes and manual retries must supersede an in-flight translation.
    private func restartTranslation(reRecognize: Bool) {
        work?.cancel()
        work = nil
        generation += 1
        if reRecognize {
            recognizedSource = nil
            lines = []
            paragraphs = []
            refreshDisplayed()
            setChromeStatus(String(localized: "正在识别"), working: true)
            InputDiagnostics.record("screen-reocr", direction.id)
        }
        work = Task { [weak self] in
            await self?.retranslate(reRecognizing: reRecognize)
        }
    }

    private func retranslate(reRecognizing: Bool = false) async {
        let token = generation
        pinModel.directionTitle = direction.compactTitle
        setChromeStatus(reRecognizing ? String(localized: "正在识别") : String(localized: "正在翻译"), working: true)
        do {
            if reRecognizing {
                let languages = ScreenTranslate.ocrLanguageHints(
                    source: direction.source,
                    target: direction.target
                )
                async let recognized = ScreenOCRService.recognize(originalImage, languages: languages)
                async let prepared: Void = prepareEngine()
                let recognizedLines = try await ScreenFontWeightService.annotate(try await recognized, image: originalImage, enabled: fontWeightDetection)
                guard token == generation, !Task.isCancelled else { return }
                lines = recognizedLines
                recognizedSource = direction.source
                if recognizedLines.isEmpty {
                    paragraphs = []
                    refreshDisplayed()
                    setChromeStatus(String(localized: "没有识别到文字"), working: false)
                    return
                }
                try await prepared
            } else {
                try await prepareEngine()
            }
            guard token == generation, !Task.isCancelled else { return }
            setChromeStatus(String(localized: "正在翻译"), working: true)
            var grouped = ScreenTranslate.groupParagraphs(from: lines, canvasSize: originalImage.size)
            guard !grouped.isEmpty else {
                paragraphs = []
                refreshDisplayed()
                setChromeStatus("", working: false)
                return
            }
            let probes = backdropProbeItems(for: grouped)
            async let backdrop: Void? = pinPanel?.prepareBackdrop(items: probes)
            paragraphs = grouped
            refreshDisplayed()
            let originals = grouped.map(\.original)
            let missing = translationCache.missing(originals, direction: direction.id)
            let fresh = missing.isEmpty ? [] : try await translation.translateBatch(missing)
            await backdrop
            guard token == generation, !Task.isCancelled else { return }
            let freshByText = Dictionary(uniqueKeysWithValues: zip(missing, fresh))
            for index in grouped.indices {
                grouped[index].translation = freshByText[grouped[index].original]
                    ?? translationCache.value(grouped[index].original, direction: direction.id) ?? grouped[index].original
            }
            for (text, translation) in zip(missing, fresh) {
                translationCache.store(text, translation: translation, direction: direction.id)
            }
            applyNavigationLabels(&grouped)
            paragraphs = grouped
            refreshDisplayed()
            guard token == generation, !Task.isCancelled else { return }
            if let polish {
                setChromeStatus(String(localized: "正在润色"), working: true)
                let sourceName = direction.source.displayName
                let targetName = direction.target.displayName
                // Bound concurrent network work, and publish one coherent result
                // instead of moving the page after every polished paragraph.
                for start in stride(from: 0, to: grouped.count, by: 4) {
                    guard token == generation, !Task.isCancelled else { return }
                    let inputs = (start..<min(start + 4, grouped.count)).map {
                        ($0, grouped[$0], ScreenTranslate.translationContext(for: $0, paragraphs: grouped))
                    }
                    let tasks = inputs.map { index, paragraph, context in
                        Task { @MainActor () -> (Int, String?) in
                            let result = try? await polish(paragraph.original, paragraph.translation, sourceName, targetName, context)
                            return (index, result)
                        }
                    }
                    var results: [(Int, String?)] = []
                    for task in tasks { results.append(await task.value) }
                    guard token == generation, !Task.isCancelled else { return }
                    for (index, result) in results {
                        if let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            grouped[index].translation = result
                        }
                    }
                }
                applyNavigationLabels(&grouped)
                paragraphs = grouped
                refreshDisplayed()
                guard token == generation, !Task.isCancelled else { return }
            }
            setChromeStatus("", working: false)
            InputDiagnostics.record("screen-translated", "paragraphs=\(grouped.count)")
        } catch is CancellationError {
        } catch {
            guard token == generation else { return }
            setChromeStatus(error.localizedDescription, working: false)
            onError?(error.localizedDescription)
        }
    }

    private func applyNavigationLabels(_ grouped: inout [ScreenParagraph]) {
        for index in grouped.indices {
            if let text = ScreenTranslate.navigationTranslation(for: index, paragraphs: grouped,
                canvasSize: originalImage.size, source: direction.source, target: direction.target) {
                grouped[index].translation = text
            }
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

    /// Probe blocks include untranslated paragraphs so the live blur radius is
    /// based on all OCR blocks, not only the first paragraph that finishes.
    private func backdropProbeItems(for grouped: [ScreenParagraph]) -> [ScreenLaidOutBlock] {
        var probes = grouped
        for index in probes.indices where probes[index].translation.isEmpty {
            probes[index].translation = probes[index].original
        }
        return ScreenTranslate.layoutPlates(probes, canvasSize: originalImage.size)
    }

    private func refreshDisplayed() {
        pinModel.overlayEnabled = overlayEnabled
        pinModel.fullText = paragraphs.map(\.translation).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let items = ScreenTranslate.layoutPlates(paragraphs, canvasSize: originalImage.size)
        pinPanel?.updateOverlay(items: items, overlayEnabled: overlayEnabled)
        pinPanel?.setWorking(pinModel.isWorking)
    }

    private func renderedOverlay() -> NSImage {
        guard overlayEnabled else { return originalImage }
        let sourceCanvas = originalImage.size
        let items = pinPanel?.displayedItemsForCopy()
            ?? ScreenTranslate.layoutPlates(paragraphs, canvasSize: sourceCanvas)
        return ScreenPinRenderer.composite(
            image: originalImage,
            items: items,
            canvasSize: sourceCanvas,
            overlayEnabled: !items.isEmpty
        )
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
