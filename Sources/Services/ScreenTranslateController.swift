import AppKit
import QuartzCore
import Carbon.HIToolbox
import SwiftUI
import Translation

@MainActor
@Observable
final class ScreenPinModel {
    var original = NSImage()
    var overlayEnabled = true
    var directionTitle = ""
    var status = ""
    var isWorking = false
    var fullText = ""
    var translationConfiguration: TranslationSession.Configuration?
}

@MainActor
final class ScreenTranslateController {
    private(set) var isSelecting = false
    private(set) var isPinVisible = false
    var isActive: Bool { isSelecting || isPinVisible }

    var overlayEnabled = true
    private(set) var direction = TranslationDirection(source: .zhHans, target: .en)
    var onError: ((String) -> Void)?
    var onSelectionEnded: (() -> Void)?
    var onPinVisibilityChanged: ((Bool) -> Void)?
    var onScreenActiveChanged: ((Bool) -> Void)?
    var polish: ((String, String, String, String, String) async throws -> String)?

    private let pinModel = ScreenPinModel()
    private let engine = TranslationEngine()
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
        // A Control hold may still become a chord. Keep keyboard focus in the
        // original app so the event tap can cancel selection without stealing it.
        if !preserveKeyboardFocus {
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
        isPinVisible = false
        onPinVisibilityChanged?(false)
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
        persistDirection()
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
        onSelectionEnded?()
        let token = generation
        persistDirection()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await ScreenCaptureService.capture(rectInScreen: rect, screen: screen)
                guard token == self.generation, !Task.isCancelled else { return }
                self.originalImage = image
                self.lines = []
                self.paragraphs = []
                self.showPin(image: image, at: rect)
                self.setChromeStatus("正在识别", working: true)
                let languages = ScreenTranslate.ocrLanguageHints(
                    source: self.direction.source,
                    target: self.direction.target
                )
                async let recognized = ScreenOCRService.recognize(image, languages: languages)
                async let prepared: Void = self.prepareEngine()
                let lines = try await ScreenFontWeightService.annotate(try await recognized, image: image)
                guard token == self.generation, !Task.isCancelled else { return }
                self.lines = lines
                self.recognizedSource = self.direction.source
                if lines.isEmpty {
                    self.setChromeStatus("没有识别到文字", working: false)
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

    /// Direction changes and manual retries must supersede an in-flight
    /// translation. Previously both tasks shared one generation and could
    /// interleave, letting the old direction overwrite the new one.
    private func restartTranslation(reRecognize: Bool) {
        work?.cancel()
        work = nil
        generation += 1
        if reRecognize {
            recognizedSource = nil
            lines = []
            paragraphs = []
            refreshDisplayed()
            setChromeStatus("正在识别", working: true)
            InputDiagnostics.record("screen-reocr", direction.id)
        }
        work = Task { [weak self] in
            await self?.retranslate(reRecognizing: reRecognize)
        }
    }

    private func retranslate(reRecognizing: Bool = false) async {
        let token = generation
        pinModel.directionTitle = direction.compactTitle
        setChromeStatus(reRecognizing ? "正在识别" : "正在翻译", working: true)
        do {
            if reRecognizing {
                let languages = ScreenTranslate.ocrLanguageHints(
                    source: direction.source,
                    target: direction.target
                )
                async let recognized = ScreenOCRService.recognize(originalImage, languages: languages)
                async let prepared: Void = prepareEngine()
                let recognizedLines = try await ScreenFontWeightService.annotate(try await recognized, image: originalImage)
                guard token == generation, !Task.isCancelled else { return }
                lines = recognizedLines
                recognizedSource = direction.source
                if recognizedLines.isEmpty {
                    paragraphs = []
                    refreshDisplayed()
                    setChromeStatus("没有识别到文字", working: false)
                    return
                }
                try await prepared
            } else {
                try await prepareEngine()
            }
            guard token == generation, !Task.isCancelled else { return }
            setChromeStatus("正在翻译", working: true)
            var grouped = ScreenTranslate.groupParagraphs(from: lines, canvasSize: originalImage.size)
            guard !grouped.isEmpty else {
                paragraphs = []
                refreshDisplayed()
                setChromeStatus("", working: false)
                return
            }
            async let backdrop: Void? = pinPanel?.prepareBackdrop(items: backdropProbeItems(for: grouped))
            paragraphs = grouped
            refreshDisplayed()
            let originals = grouped.map(\.original)
            let missing = translationCache.missing(originals, direction: direction.id)
            let fresh = missing.isEmpty ? [] : try await engine.translateBatch(missing)
            await backdrop
            guard token == generation, !Task.isCancelled else { return }
            let freshByText = Dictionary(uniqueKeysWithValues: zip(missing, fresh))
            // Resolve this request before inserting into the bounded cache:
            // eviction during a large page must not drop its current results.
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
                setChromeStatus("正在润色", working: true)
                let sourceName = direction.source.displayName
                let targetName = direction.target.displayName
                // Bound concurrent network work, and publish one coherent result
                // instead of moving the page after every polished paragraph.
                for start in stride(from: 0, to: grouped.count, by: 4) {
                    guard token == generation, !Task.isCancelled else { return }
                    let inputs = (start..<min(start + 4, grouped.count)).map {
                        ($0, grouped[$0], ScreenTranslate.translationContext(for: $0, paragraphs: grouped))
                    }
                    let results = await withTaskGroup(of: (Int, String?).self) { group in
                        for (index, paragraph, context) in inputs {
                            group.addTask { @MainActor in
                                let result = try? await polish(paragraph.original, paragraph.translation, sourceName, targetName, context)
                                return (index, result)
                            }
                        }
                        var results: [(Int, String?)] = []
                        for await result in group { results.append(result) }
                        return results
                    }
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

    func attachTranslation(_ session: TranslationSession) async {
        do {
            try await engine.attach(session)
        } catch {
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
        if preparedDirection == direction, engine.isReady || engine.isPassthrough { return }
        engine.reset()
        preparedDirection = nil
        pinModel.translationConfiguration = nil
        if direction.source == direction.target {
            engine.enablePassthrough()
            preparedDirection = direction
            pinPanel?.refreshChrome()
            return
        }
        try await engine.prepareInstalled(
            source: direction.source.translationLanguage,
            target: direction.target.translationLanguage
        )
        if engine.needsDownload {
            pinModel.translationConfiguration = TranslationSession.Configuration(
                source: direction.source.translationLanguage,
                target: direction.target.translationLanguage
            )
            pinPanel?.refreshChrome()
            setChromeStatus("正在下载翻译模型", working: true)
            for _ in 0..<200 {
                if engine.isReady { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if !engine.isReady { throw TranslationEngineError.notReady }
        }
        preparedDirection = direction
    }

    private func showPin(image: NSImage, at rect: CGRect) {
        pinModel.original = image
        pinModel.overlayEnabled = overlayEnabled
        pinModel.directionTitle = direction.compactTitle
        pinModel.status = ""
        let panel = pinPanel ?? ScreenPinPanel(model: pinModel)
        panel.onToggleOverlay = { [weak self] in self?.toggleOverlay() }
        panel.onCopy = { [weak self] in _ = self?.copyImage() }
        panel.onClose = { [weak self] in self?.cancel() }
        panel.onCycle = { [weak self] in
            guard let self else { return }
            self.cycleDirection(a: self.pairA, b: self.pairB)
        }
        panel.onAttachTranslation = { [weak self] session in
            await self?.attachTranslation(session)
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

    private func pinPanelCanvasSize() -> CGSize {
        let size = pinPanel?.canvasSize ?? originalImage.size
        if size.width > 1, size.height > 1 { return size }
        return originalImage.size
    }

    private func persistDirection() {
        UserDefaults.standard.set(direction.source.rawValue, forKey: "screenTranslateSource")
        UserDefaults.standard.set(direction.target.rawValue, forKey: "screenTranslateTarget")
    }

    private func tearDownSelection() {
        isSelecting = false
        for panel in selectionPanels { panel.orderOut(nil) }
        selectionPanels = []
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                if self.pinPanel?.closeTranslationDetail() == true { return nil }
                self.cancel()
                return nil
            }
            // Let selection/copy/scroll keys reach the expanded text reader.
            if self.pinPanel?.hasTranslationDetail == true { return event }
            if self.isPinVisible, event.charactersIgnoringModifiers == "c",
               event.modifierFlags.contains(.command) {
                _ = self.copyImage()
                return nil
            }
            if self.isPinVisible, event.keyCode == UInt16(kVK_Tab) {
                self.toggleOverlay()
                return nil
            }
            if self.isPinVisible, event.keyCode == UInt16(kVK_Space) {
                self.toggleOverlay()
                return nil
            }
            if self.isPinVisible, event.charactersIgnoringModifiers == "r" {
                self.restartTranslation(reRecognize: false)
                return nil
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private final class ScreenSelectionPanel: NSPanel {
    var onDragEnded: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private let canvas: ScreenSelectionView

    init(screen: NSScreen, title: String) {
        let canvas = ScreenSelectionView(frame: screen.frame)
        canvas.title = title
        canvas.screenFrame = screen.frame
        self.canvas = canvas
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        canvas.onDragEnded = { [weak self] rect in self?.onDragEnded?(rect) }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        setFrame(screen.frame, display: true)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        sharingType = .none
        hidesOnDeactivate = false
        contentView = canvas
        canvas.frame = CGRect(origin: .zero, size: screen.frame.size)
        canvas.refreshHover(at: NSEvent.mouseLocation)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setTitle(_ title: String) {
        canvas.title = title
        canvas.needsDisplay = true
    }
}

private final class ScreenSelectionView: NSView {
    var title = ""
    var screenFrame = CGRect.zero
    var onDragEnded: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var dragging = false
    private var hoverBounds: CGRect?

    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard start == nil else { return }
        refreshHover(at: convertToScreen(event.locationInWindow))
    }

    override func mouseEntered(with event: NSEvent) {
        guard start == nil else { return }
        refreshHover(at: convertToScreen(event.locationInWindow))
    }

    func refreshHover(at point: CGPoint) {
        let bounds = ScreenWindowProbe.hoverBounds(at: point, excludingPID: ProcessInfo.processInfo.processIdentifier)
        let clipped = bounds.flatMap { $0.intersection(screenFrame) }
        hoverBounds = (clipped?.isNull == false && (clipped?.width ?? 0) > 8) ? clipped : nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convertToScreen(event.locationInWindow)
        current = start
        dragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convertToScreen(event.locationInWindow)
        if let start, let current, hypot(current.x - start.x, current.y - start.y) >= ScreenTranslate.dragThreshold {
            dragging = true
            hoverBounds = nil
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convertToScreen(event.locationInWindow)
        let dragRect = selectionRect
        let snap = hoverBounds
        start = nil
        current = nil
        dragging = false
        needsDisplay = true
        if dragRect.width >= ScreenTranslate.minimumSelection, dragRect.height >= ScreenTranslate.minimumSelection {
            onDragEnded?(dragRect)
            return
        }
        if let snap, snap.width >= ScreenTranslate.minimumSelection, snap.height >= ScreenTranslate.minimumSelection {
            onDragEnded?(snap)
            return
        }
        onCancel?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = highlightRect
        let dim = NSBezierPath(rect: bounds)
        if highlight.width >= 2, highlight.height >= 2 {
            dim.append(NSBezierPath(roundedRect: highlight, xRadius: ScreenTranslate.windowCornerRadius, yRadius: ScreenTranslate.windowCornerRadius))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()
        if highlight.width >= 2, highlight.height >= 2 {
            let radius = ScreenTranslate.windowCornerRadius
            let outer = NSBezierPath(roundedRect: highlight.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            outer.lineWidth = 3
            NSColor.black.withAlphaComponent(0.35).setStroke()
            outer.stroke()
            let inner = NSBezierPath(roundedRect: highlight.insetBy(dx: 1.5, dy: 1.5), xRadius: max(8, radius - 1), yRadius: max(8, radius - 1))
            inner.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.92).setStroke()
            inner.stroke()
        }
        let prompt: String
        if dragging {
            prompt = title.isEmpty ? "松开翻译" : "\(title)  ·  松开翻译"
        } else if hoverBounds != nil {
            prompt = title.isEmpty ? "点击框住窗口，拖动自己划" : "\(title)  ·  点击框住，拖动自选"
        } else {
            prompt = title.isEmpty ? "移到窗口上或拖动划选" : "\(title)  ·  移到窗口上或拖动划选"
        }
        let chip = NSAttributedString(
            string: prompt,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let size = chip.size()
        let mousePoint = current ?? NSEvent.mouseLocation
        let mouse = convertFromScreen(CGRect(origin: mousePoint, size: .zero)).origin
        let chipRect = CGRect(x: mouse.x + 16, y: mouse.y - 28, width: size.width + 16, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 8, yRadius: 8).fill()
        chip.draw(at: NSPoint(x: chipRect.minX + 8, y: chipRect.minY + 5))
    }

    private var highlightRect: CGRect {
        if dragging { return convertFromScreen(selectionRect) }
        if let hoverBounds { return convertFromScreen(hoverBounds) }
        return .zero
    }

    private var selectionRect: CGRect {
        guard let start, let current else { return .zero }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func convertToScreen(_ windowPoint: CGPoint) -> CGPoint {
        window?.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin ?? windowPoint
    }

    private func convertFromScreen(_ screenRect: CGRect) -> CGRect {
        window?.convertFromScreen(screenRect) ?? screenRect
    }
}


private final class ScreenPinFreezePanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        contentView = ScreenPinFreezeView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ScreenPinFreezeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)" ) }

    override var isOpaque: Bool { false }

    // Consume all pointer/scroll input while the captured preview is visible.
    // The toolbar is a separate child window and remains interactive.
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func scrollWheel(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
}

private final class ScreenPinPassThroughView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

private final class ScreenPinBorderView: NSView {
    private let glowHost = CALayer()
    private let glowGradient = CAGradientLayer()
    private let glowMask = CAShapeLayer()
    private let idleOuter = CAShapeLayer()
    private let idleLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glowGradient.type = .axial
        glowGradient.startPoint = CGPoint(x: 0, y: 0.5)
        glowGradient.endPoint = CGPoint(x: 1, y: 0.5)
        glowGradient.colors = [
            NSColor(red: 0.20, green: 0.55, blue: 1, alpha: 1).cgColor,
            NSColor(red: 0.25, green: 0.95, blue: 0.92, alpha: 1).cgColor,
            NSColor(red: 0.72, green: 0.38, blue: 1, alpha: 1).cgColor,
            NSColor(red: 1.0, green: 0.42, blue: 0.72, alpha: 1).cgColor,
            NSColor(red: 0.20, green: 0.55, blue: 1, alpha: 1).cgColor
        ]
        glowGradient.locations = [0, 0.25, 0.5, 0.75, 1]
        glowHost.addSublayer(glowGradient)
        glowHost.mask = glowMask
        glowHost.isHidden = true
        idleOuter.fillColor = NSColor.clear.cgColor
        idleOuter.strokeColor = NSColor.black.withAlphaComponent(0.38).cgColor
        idleOuter.lineWidth = 3
        idleLayer.fillColor = NSColor.clear.cgColor
        idleLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        idleLayer.lineWidth = 1.6
        layer?.addSublayer(glowHost)
        layer?.addSublayer(idleOuter)
        layer?.addSublayer(idleLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowHost.frame = bounds
        glowGradient.frame = bounds
        let radius = ScreenTranslate.windowCornerRadius
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 1.2, dy: 1.2),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        glowMask.fillColor = NSColor.clear.cgColor
        glowMask.strokeColor = NSColor.black.cgColor
        glowMask.lineWidth = 2.4
        glowMask.lineJoin = .round
        glowMask.path = path
        idleOuter.path = path
        idleOuter.frame = bounds
        idleLayer.path = path
        idleLayer.frame = bounds
        CATransaction.commit()
    }

    func setWorking(_ working: Bool) {
        glowGradient.removeAnimation(forKey: "flow")
        glowHost.isHidden = !working
        idleOuter.isHidden = working
        idleLayer.isHidden = working
        if working {
            // Move the spectrum itself instead of rotating a conic layer. This keeps
            // the highlight continuous around the rounded border, like a Siri-style
            // light sweep rather than a visibly segmented spinner.
            let flow = CAKeyframeAnimation(keyPath: "locations")
            flow.values = [
                [-0.80, -0.55, -0.30, -0.05, 0.20],
                [-0.20, 0.05, 0.30, 0.55, 0.80],
                [0.20, 0.45, 0.70, 0.95, 1.20]
            ]
            flow.keyTimes = [0, 0.5, 1]
            flow.duration = 1.35
            flow.repeatCount = .infinity
            flow.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            flow.isRemovedOnCompletion = false
            glowGradient.add(flow, forKey: "flow")
        }
    }
}

private final class ScreenPinCanvasView: NSView {
    private var sourceImage = NSImage()
    private var scrollOffsets: [String: CGFloat] = [:]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setSource(_ image: NSImage) {
        sourceImage = image
        scrollOffsets = [:]
        frame = CGRect(origin: .zero, size: image.size)
        needsDisplay = true
    }

    func update(
        items: [ScreenLaidOutBlock],
        blurredImage: CGImage?,
        canvasSize: CGSize
    ) {
        for item in displayedItemsForCopy() {
            scrollOffsets[NSStringFromRect(item.sourceRect)] = item.textScrollOffset
        }
        let visible = items.filter { !$0.text.isEmpty && !$0.rect.isEmpty }.map { item in
            var next = item
            next.textScrollOffset = scrollOffsets[NSStringFromRect(item.sourceRect)] ?? 0
            return next
        }
        while subviews.count < visible.count {
            addSubview(ScreenPinBlockView(
                item: visible[subviews.count],
                blurredImage: blurredImage,
                canvasSize: canvasSize
            ))
        }
        for (index, item) in visible.enumerated() {
            guard let block = subviews[index] as? ScreenPinBlockView else { continue }
            block.configure(item: item, blurredImage: blurredImage, canvasSize: canvasSize)
        }
        if subviews.count > visible.count {
            subviews[visible.count...].forEach { $0.removeFromSuperview() }
        }
        needsDisplay = true
    }

    func displayedItemsForCopy() -> [ScreenLaidOutBlock] {
        subviews.compactMap { ($0 as? ScreenPinBlockView)?.displayedItem }
    }

    override func draw(_ dirtyRect: NSRect) {
        sourceImage.draw(
            in: CGRect(origin: .zero, size: sourceImage.size),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none.rawValue]
        )
    }
}

private final class ScreenPinBlockView: NSView {
    private var item: ScreenLaidOutBlock
    private var blurredImage: CGImage?
    private var canvasSize: CGSize
    private let textScroll = NSScrollView()
    private let textDocument = ScreenPinTextView()
    private var detailPopover: NSPopover?

    init(
        item: ScreenLaidOutBlock,
        blurredImage: CGImage?,
        canvasSize: CGSize
    ) {
        self.item = item
        self.blurredImage = blurredImage
        self.canvasSize = canvasSize
        super.init(frame: item.rect)
        wantsLayer = true
        layer?.masksToBounds = true
        textScroll.drawsBackground = false
        textScroll.contentView.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.scrollerStyle = .overlay
        textScroll.autohidesScrollers = true
        textScroll.hasHorizontalScroller = false
        textScroll.verticalScrollElasticity = .none
        textScroll.documentView = textDocument
        textDocument.onExpand = { [weak self] in self?.showFullTranslation() }
        addSubview(textScroll)
        configure(item: item, blurredImage: blurredImage, canvasSize: canvasSize)
    }

    func configure(
        item: ScreenLaidOutBlock,
        blurredImage: CGImage?,
        canvasSize: CGSize
    ) {
        if self.item.text != item.text || self.item.sourceRect != item.sourceRect { detailPopover?.close() }
        self.item = item
        self.blurredImage = blurredImage
        self.canvasSize = canvasSize
        frame = item.rect
        let oldY = item.textScrollOffset
        textScroll.frame = bounds
        textDocument.item = item
        textDocument.frame = CGRect(x: 0, y: 0, width: bounds.width,
            height: max(bounds.height, item.textContentHeight))
        textScroll.hasVerticalScroller = textDocument.frame.height > bounds.height + 1
        textDocument.canExpand = textScroll.hasVerticalScroller
        textScroll.contentView.scroll(to: NSPoint(x: 0, y: min(oldY, max(0, textDocument.frame.height - bounds.height))))
        textScroll.reflectScrolledClipView(textScroll.contentView)
        textDocument.needsDisplay = true
        let overflowHint = textScroll.hasVerticalScroller
            ? item.text + "\n\n点击展开，或在这段文字内滚动" : nil
        toolTip = overflowHint
        textScroll.toolTip = overflowHint
        textDocument.toolTip = overflowHint
        needsDisplay = true
    }

    func showFullTranslation() {
        guard textScroll.hasVerticalScroller, window != nil else { return }
        detailPopover?.close()
        let controller = ScreenTranslationDetailController(text: item.text)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        detailPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    var hasTranslationDetail: Bool { detailPopover?.isShown == true }
    func closeTranslationDetail() { detailPopover?.close() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { detailPopover?.close() }
        super.viewWillMove(toWindow: newWindow)
    }

    var displayedItem: ScreenLaidOutBlock {
        var current = item
        current.textScrollOffset = textScroll.contentView.bounds.minY
        return current
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(5, bounds.height / 2.4)
        let plate = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        plate.addClip()
        drawBackdrop()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()

        plate.lineWidth = 0.5
        borderColor().setStroke()
        plate.stroke()

    }

    private func drawBackdrop() {
        if let blurredImage {
            drawCroppedBackdrop(blurredImage)
            return
        }
        item.background.withAlphaComponent(0.97).setFill()
    }

    private func drawCroppedBackdrop(_ image: CGImage) {
        guard canvasSize.width > 0, canvasSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            item.background.withAlphaComponent(0.97).setFill()
            return
        }
        let crop = CGRect(
            x: item.sourceRect.minX / canvasSize.width * CGFloat(image.width),
            y: item.sourceRect.minY / canvasSize.height * CGFloat(image.height),
            width: item.sourceRect.width / canvasSize.width * CGFloat(image.width),
            height: item.sourceRect.height / canvasSize.height * CGFloat(image.height)
        ).integral
        guard let cropped = image.cropping(to: crop) else {
            item.background.withAlphaComponent(0.97).setFill()
            return
        }
        let backdrop = NSImage(cgImage: cropped, size: bounds.size)
        backdrop.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        veilColor().setFill()
    }

    private func veilColor() -> NSColor {
        return isLightBackdrop()
            ? NSColor.white.withAlphaComponent(0.42)
            : NSColor.black.withAlphaComponent(0.34)
    }

    private func isLightBackdrop() -> Bool {
        let red = item.background.redComponent
        let green = item.background.greenComponent
        let blue = item.background.blueComponent
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.58
    }

    private func borderColor() -> NSColor {
        NSColor.black.withAlphaComponent(isLightBackdrop() ? 0.06 : 0.18)
    }
}

private final class ScreenPinTextView: NSView {
    var item: ScreenLaidOutBlock?
    var onExpand: (() -> Void)?
    var canExpand = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func resetCursorRects() {
        if canExpand { addCursorRect(visibleRect, cursor: .pointingHand) }
    }
    override func mouseDown(with event: NSEvent) {
        if canExpand { onExpand?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ScreenPinRenderer.drawInk(item, in: context, visibleRange: visibleRect.minY...visibleRect.maxY)
    }
}

private final class ScreenTranslationDetailController: NSViewController {
    private let text: String
    init(text: String) { self.text = text; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func loadView() {
        let width: CGFloat = 360
        let height = min(400, max(90, ScreenTranslate.textHeight(text: text, fontSize: 15,
            width: width - 32, heading: false) + 20))
        view = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height + 52))
        let title = NSTextField(labelWithString: "完整译文")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 16, y: height + 18, width: 190, height: 18)
        view.addSubview(title)
        let copy = NSButton(title: "复制文字", target: self, action: #selector(copyText))
        copy.bezelStyle = .rounded
        copy.frame = CGRect(x: width - 100, y: height + 12, width: 86, height: 28)
        view.addSubview(copy)
        let scroll = NSScrollView(frame: CGRect(x: 12, y: 12, width: width - 24, height: height))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let content = NSTextView(frame: CGRect(x: 0, y: 0, width: width - 24, height: height))
        content.isEditable = false
        content.isSelectable = true
        content.drawsBackground = false
        content.font = .systemFont(ofSize: 15)
        content.textColor = .labelColor
        content.string = text
        content.textContainerInset = CGSize(width: 4, height: 4)
        content.isVerticallyResizable = true
        content.autoresizingMask = [.width]
        content.textContainer?.widthTracksTextView = true
        scroll.documentView = content
        view.addSubview(scroll)
    }
    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class ScreenPinPanel: NSPanel {
    var onToggleOverlay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onCycle: (() -> Void)?
    var onAttachTranslation: ((TranslationSession) async -> Void)?
    private var fullTextPopover: NSPopover?
    private var sourcePixels: CGImage?
    var hasTranslationDetail: Bool {
        fullTextPopover?.isShown == true || canvasView.subviews.contains { ($0 as? ScreenPinBlockView)?.hasTranslationDetail == true }
    }
    @discardableResult func closeTranslationDetail() -> Bool {
        let wasOpen = hasTranslationDetail
        fullTextPopover?.close()
        for block in canvasView.subviews.compactMap({ $0 as? ScreenPinBlockView }) { block.closeTranslationDetail() }
        return wasOpen
    }
    private(set) var canvasSize = CGSize.zero
    private let model: ScreenPinModel
    private let chrome: ScreenPinChromePanel
    private let card = NSView()
    private let scrollView = NSScrollView()
    private let canvasView = ScreenPinCanvasView()
    private let borderView = ScreenPinBorderView()
    private var sourceImage = NSImage()
    private var blurredBackdropImage: CGImage?
    private var freezePanels: [ScreenPinFreezePanel] = []
    private let glowPad: CGFloat = 10
    private var pinRect = CGRect.zero
    private var displayRect = CGRect.zero
    private var showingOverlay = true
    private var translatedScrollY: CGFloat = 0
    private var sourceStyles: [String: ScreenLaidOutBlock] = [:]

    init(model: ScreenPinModel) {
        self.model = model
        chrome = ScreenPinChromePanel(model: model)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        sharingType = .none
        let root = ScreenPinPassThroughView()
        contentView = root

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.clear.cgColor
        card.layer?.cornerRadius = ScreenTranslate.windowCornerRadius
        card.layer?.masksToBounds = true

        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .automatic
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = canvasView

        card.addSubview(scrollView)
        root.addSubview(card)
        root.addSubview(borderView)

        chrome.onToggleOverlay = { [weak self] in self?.onToggleOverlay?() }
        chrome.onCopy = { [weak self] in self?.onCopy?() }
        chrome.onRead = { [weak self] in self?.showFullText() }
        chrome.onClose = { [weak self] in self?.onClose?() }
        chrome.onCycle = { [weak self] in self?.onCycle?() }
        chrome.onAttachTranslation = { [weak self] session in
            await self?.onAttachTranslation?(session)
        }
        addChildWindow(chrome, ordered: .above)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showFullText() {
        guard !model.fullText.isEmpty, let anchor = chrome.contentView else { return }
        closeTranslationDetail()
        let controller = ScreenTranslationDetailController(text: model.fullText)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        fullTextPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func present(source: NSImage, at rect: CGRect) {
        pinRect = rect
        sourceImage = source
        sourcePixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        blurredBackdropImage = nil
        sourceStyles = [:]
        canvasView.setSource(source)
        layoutCard(size: rect.size)
        refreshChrome()
        installFreezePanels()
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        chrome.orderFrontRegardless()
        makeKey()
    }

    private func layoutCard(size: CGSize) {
        canvasSize = size
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(pinRect) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? pinRect
        displayRect = ScreenTranslate.visiblePinRect(
            content: size,
            originRect: pinRect,
            visible: visible
        )
        let padded = displayRect.insetBy(dx: -glowPad, dy: -glowPad)
        setFrame(padded, display: true)
        card.frame = CGRect(x: glowPad, y: glowPad, width: displayRect.width, height: displayRect.height)
        scrollView.frame = card.bounds
        canvasView.frame = CGRect(origin: .zero, size: size)
        scrollView.hasVerticalScroller = size.height > displayRect.height + 1
        borderView.frame = card.frame
    }

    private func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
    }

    private func installFreezePanels() {
        guard freezePanels.isEmpty else { return }
        // The pinned frame is a preview of a single captured moment. Keep the
        // source application from scrolling or changing underneath it while the
        // user compares the translation. The toolbar remains a child window above
        // these shields, and Esc still closes the preview.
        freezePanels = NSScreen.screens.map { screen in
            let panel = ScreenPinFreezePanel(screen: screen)
            panel.orderFrontRegardless()
            return panel
        }
    }

    func prepareBackdrop(items: [ScreenLaidOutBlock]) async {
        guard let cgImage = sourcePixels,
              blurredBackdropImage == nil else { return }
        let source = sourceImage
        let size = canvasSize
        let task = Task.detached(priority: .userInitiated) { () -> (CGImage?, [ScreenLaidOutBlock]) in
            guard !Task.isCancelled else { return (nil, []) }
            let styles = ScreenPinRenderer.prepareItems(items, image: cgImage, canvasSize: size)
            guard !Task.isCancelled else { return (nil, []) }
            let blurred = ScreenPinRenderer.blurredBackdrop(image: cgImage, items: items, canvasSize: size)
            return (blurred, styles)
        }
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard !Task.isCancelled, sourceImage === source else { return }
        blurredBackdropImage = result.0
        for item in result.1 {
            sourceStyles[NSStringFromRect(item.sourceRect)] = item
        }
    }

    func updateOverlay(items: [ScreenLaidOutBlock], overlayEnabled: Bool) {
        guard let cgImage = sourcePixels else {
            canvasView.update(items: [], blurredImage: nil, canvasSize: canvasSize)
            return
        }
        let missing = items.filter { sourceStyles[NSStringFromRect($0.sourceRect)] == nil }
        if overlayEnabled, !missing.isEmpty {
            for item in ScreenPinRenderer.prepareItems(missing, image: cgImage, canvasSize: canvasSize) {
                sourceStyles[NSStringFromRect(item.sourceRect)] = item
            }
        }
        let prepared: [ScreenLaidOutBlock] = overlayEnabled ? ScreenTranslate.nonOverlapping(items.map { item in
            var next = item
            if let style = sourceStyles[NSStringFromRect(item.sourceRect)] {
                next.background = style.background
                next.foreground = style.foreground
                next.centered = style.centered
                next = ScreenTranslate.fitViewport(next, available: style.availableRect)
            }
            return next
        }) : []
        if overlayEnabled, !prepared.isEmpty, blurredBackdropImage == nil {
            blurredBackdropImage = ScreenPinRenderer.blurredBackdrop(
                image: cgImage,
                items: prepared,
                canvasSize: canvasSize
            )
        }
        let clip = scrollView.contentView
        if showingOverlay { translatedScrollY = clip.bounds.minY }
        let height = overlayEnabled
            ? ScreenTranslate.contentHeight(items: prepared, canvasHeight: sourceImage.size.height)
            : sourceImage.size.height
        canvasView.setFrameSize(CGSize(width: sourceImage.size.width, height: height))
        scrollView.hasVerticalScroller = height > displayRect.height + 1
        let scrollY = overlayEnabled ? translatedScrollY : 0
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, scrollY), max(0, height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
        showingOverlay = overlayEnabled
        canvasView.update(
            items: prepared,
            blurredImage: blurredBackdropImage,
            canvasSize: canvasSize
        )
        refreshChrome()
    }

    func displayedItemsForCopy() -> [ScreenLaidOutBlock] {
        canvasView.displayedItemsForCopy()
    }

    func setWorking(_ working: Bool) {
        borderView.setWorking(working)
    }

    func refreshChrome() {
        chrome.rebind()
        if displayRect.width > 0 {
            chrome.place(beside: displayRect)
        } else if pinRect.width > 0 {
            chrome.place(beside: pinRect)
        }
    }

    override func orderOut(_ sender: Any?) {
        closeTranslationDetail()
        chrome.orderOut(sender)
        for panel in freezePanels { panel.orderOut(sender) }
        freezePanels = []
        super.orderOut(sender)
    }
}

private final class ScreenPinChromePanel: NSPanel {
    var onToggleOverlay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRead: (() -> Void)?
    var onClose: (() -> Void)?
    var onCycle: (() -> Void)?
    var onAttachTranslation: ((TranslationSession) async -> Void)?
    private let model: ScreenPinModel
    private let hosting: NSHostingView<ScreenPinChromeView>

    init(model: ScreenPinModel) {
        self.model = model
        hosting = TransparentPinView(rootView: ScreenPinChromeView(
            model: model, onToggle: {}, onCopy: {}, onRead: {}, onClose: {}, onCycle: {}, onAttachTranslation: { _ in }
        ))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        sharingType = .none
        contentView = hosting
        rebind()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func rebind() {
        hosting.rootView = ScreenPinChromeView(
            model: model,
            onToggle: { [weak self] in self?.onToggleOverlay?() },
            onCopy: { [weak self] in self?.onCopy?() },
            onRead: { [weak self] in self?.onRead?() },
            onClose: { [weak self] in self?.onClose?() },
            onCycle: { [weak self] in self?.onCycle?() },
            onAttachTranslation: { [weak self] session in
                await self?.onAttachTranslation?(session)
            }
        )
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 168 { size.width = 168 }
        if size.height < 32 { size.height = 36 }
        setContentSize(size)
        hosting.frame = CGRect(origin: .zero, size: size)
    }

    func place(beside rect: CGRect) {
        rebind()
        let size = frame.size
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect
        var origin = NSPoint(x: rect.minX, y: rect.minY - 8 - size.height)
        if origin.y < visible.minY + 4 {
            origin.y = min(rect.maxY + 8, visible.maxY - size.height - 4)
        }
        origin.x = min(max(visible.minX + 4, origin.x), max(visible.minX + 4, visible.maxX - size.width - 4))
        setFrameOrigin(origin)
    }
}

private struct ScreenPinChromeView: View {
    @Bindable var model: ScreenPinModel
    var onToggle: () -> Void
    var onCopy: () -> Void
    var onRead: () -> Void
    var onClose: () -> Void
    var onCycle: () -> Void
    var onAttachTranslation: (TranslationSession) async -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Text(model.overlayEnabled ? "译文" : "原文")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(model.overlayEnabled ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: onCycle) {
                Text(model.directionTitle)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help("切换这块的翻译方向，不影响说话")
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            Button("复制", action: onCopy)
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
            if !model.fullText.isEmpty {
                Button("全文", action: onRead)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .help("阅读并复制完整译文")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .translationTask(model.translationConfiguration) { session in
            await onAttachTranslation(session)
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

private final class TransparentPinView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
