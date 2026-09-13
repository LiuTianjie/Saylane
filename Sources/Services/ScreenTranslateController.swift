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
    var polish: ((String, String, String, String) async throws -> String)?

    private let pinModel = ScreenPinModel()
    private let engine = TranslationEngine()
    private var preparedDirection: TranslationDirection?
    private var selectionPanels: [ScreenSelectionPanel] = []
    private var pinPanel: ScreenPinPanel?
    private var eventMonitor: Any?
    private var work: Task<Void, Never>?
    private var lines: [ScreenOCRLine] = []
    private var paragraphs: [ScreenParagraph] = []
    private var originalImage = NSImage()
    private var generation = 0
    private var pairA: AppLanguage = .zhHans
    private var pairB: AppLanguage = .en

    func beginSelection(a: AppLanguage, b: AppLanguage, last: TranslationDirection?) {
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
        NSApp.activate(ignoringOtherApps: true)
        selectionPanels.first?.makeKey()
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
        Task { await retranslate() }
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
                let languages = Array(Set([self.direction.source.speechIdentifier, self.direction.source.rawValue,
                                           self.direction.target.speechIdentifier, self.direction.target.rawValue]))
                async let recognized = ScreenOCRService.recognize(image, languages: languages)
                async let prepared: Void = self.prepareEngine()
                let lines = try await recognized
                guard token == self.generation, !Task.isCancelled else { return }
                self.lines = lines
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

    private func retranslate() async {
        let token = generation
        pinModel.directionTitle = direction.compactTitle
        setChromeStatus("正在翻译", working: true)
        do {
            try await prepareEngine()
            guard token == generation, !Task.isCancelled else { return }
            var grouped = ScreenTranslate.groupParagraphs(from: lines)
            guard !grouped.isEmpty else {
                paragraphs = []
                refreshDisplayed()
                setChromeStatus("", working: false)
                return
            }
            for index in grouped.indices {
                guard token == generation, !Task.isCancelled else { return }
                grouped[index].translation = try await engine.translate(grouped[index].original)
            }
            guard token == generation, !Task.isCancelled else { return }
            paragraphs = grouped
            refreshDisplayed()
            if let polish {
                setChromeStatus("正在润色", working: true)
                let sourceName = direction.source.displayName
                let targetName = direction.target.displayName
                for index in grouped.indices {
                    guard token == generation, !Task.isCancelled else { return }
                    do {
                        grouped[index].translation = try await polish(
                            grouped[index].original,
                            grouped[index].translation,
                            sourceName,
                            targetName
                        )
                    } catch {
                        continue
                    }
                }
                guard token == generation, !Task.isCancelled else { return }
                paragraphs = grouped
                refreshDisplayed()
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

    private func refreshDisplayed() {
        pinModel.overlayEnabled = overlayEnabled
        pinPanel?.updateOverlay(image: renderedOverlay())
        pinPanel?.setWorking(pinModel.isWorking)
    }

    private func renderedOverlay() -> NSImage {
        guard overlayEnabled else { return originalImage }
        let sourceCanvas = originalImage.size
        let items = ScreenTranslate.layoutPlates(paragraphs, canvasSize: sourceCanvas)
        let canvas = CGSize(
            width: sourceCanvas.width,
            height: ScreenTranslate.contentHeight(items: items, canvasHeight: sourceCanvas.height)
        )
        return ScreenPinRenderer.composite(
            image: originalImage,
            items: items,
            canvasSize: canvas,
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
                self.cancel()
                return nil
            }
            if self.isPinVisible, event.charactersIgnoringModifiers == "c",
               event.modifierFlags.contains(.command) {
                _ = self.copyImage()
                return nil
            }
            if self.isPinVisible, event.keyCode == UInt16(kVK_Space) {
                self.toggleOverlay()
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

private final class ScreenPinPanel: NSPanel {
    var onToggleOverlay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onCycle: (() -> Void)?
    var onAttachTranslation: ((TranslationSession) async -> Void)?
    private(set) var canvasSize = CGSize.zero
    private let model: ScreenPinModel
    private let chrome: ScreenPinChromePanel
    private let card = NSView()
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let borderView = ScreenPinBorderView()
    private var sourceImage = NSImage()
    private var freezePanels: [ScreenPinFreezePanel] = []
    private let glowPad: CGFloat = 10
    private var pinRect = CGRect.zero
    private var displayRect = CGRect.zero

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

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .center

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
        scrollView.documentView = imageView

        card.addSubview(scrollView)
        root.addSubview(card)
        root.addSubview(borderView)

        chrome.onToggleOverlay = { [weak self] in self?.onToggleOverlay?() }
        chrome.onCopy = { [weak self] in self?.onCopy?() }
        chrome.onClose = { [weak self] in self?.onClose?() }
        chrome.onCycle = { [weak self] in self?.onCycle?() }
        chrome.onAttachTranslation = { [weak self] session in
            await self?.onAttachTranslation?(session)
        }
        addChildWindow(chrome, ordered: .above)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(source: NSImage, at rect: CGRect) {
        pinRect = rect
        sourceImage = source
        layoutCard(size: rect.size)
        placeImage(source)
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
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.hasVerticalScroller = size.height > displayRect.height + 1
        borderView.frame = card.frame
    }

    private func scrollToTop() {
        let clip = scrollView.contentView
        let y = max(0, imageView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
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

    private func placeImage(_ image: NSImage) {
        imageView.image = nil
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            imageView.image = image
            return
        }
        imageView.wantsLayer = true
        imageView.layer?.contents = cgImage
        imageView.layer?.contentsGravity = .center
        let pointWidth = image.size.width
        imageView.layer?.contentsScale = pointWidth > 0 ? CGFloat(cgImage.width) / pointWidth : 1
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView
        scrollToTop()
    }

    func updateOverlay(image: NSImage) {
        let size = image.size.width > 1 && image.size.height > 1 ? image.size : pinRect.size
        layoutCard(size: CGSize(width: pinRect.width, height: size.height))
        placeImage(image)
        refreshChrome()
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
        chrome.orderOut(sender)
        for panel in freezePanels { panel.orderOut(sender) }
        freezePanels = []
        super.orderOut(sender)
    }
}

private final class ScreenPinChromePanel: NSPanel {
    var onToggleOverlay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onCycle: (() -> Void)?
    var onAttachTranslation: ((TranslationSession) async -> Void)?
    private let model: ScreenPinModel
    private let hosting: NSHostingView<ScreenPinChromeView>

    init(model: ScreenPinModel) {
        self.model = model
        hosting = TransparentPinView(rootView: ScreenPinChromeView(
            model: model, onToggle: {}, onCopy: {}, onClose: {}, onCycle: {}, onAttachTranslation: { _ in }
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
