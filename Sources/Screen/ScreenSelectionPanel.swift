import AppKit

/// Full-screen, per-display overlay for choosing the area to translate.
/// Hover snaps to the region under the pointer (a card, a field, a paragraph, else the
/// window), drag selects freely, right click or Esc cancels.
final class ScreenSelectionPanel: NSPanel {
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

    func setRegionMap(_ map: ScreenRegionMap) {
        canvas.regionMap = map
        canvas.refreshHover(at: NSEvent.mouseLocation)
    }

    func setTitle(_ title: String) {
        canvas.title = title
        canvas.needsDisplay = true
    }
}

final class ScreenSelectionView: NSView {
    var title = ""
    var screenFrame = CGRect.zero
    var onDragEnded: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var dragging = false
    private var hoverBounds: CGRect?
    /// The screen as it was when the selection opened; nil until it has been read.
    var regionMap: ScreenRegionMap?

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
        let pid = ProcessInfo.processInfo.processIdentifier
        // Over the bare desktop the wallpaper's shapes are not regions; offer the screen.
        let window = ScreenTranslate.topmostBounds(at: point, candidates: ScreenWindowProbe.onscreenCandidates(excludingPID: pid))
        let bounds = window.flatMap { regionMap?.region(at: point, within: $0) ?? $0 }
            ?? ScreenWindowProbe.hoverBounds(at: point, excludingPID: pid)
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
        // Regions inside a window are often small and square-cornered; only windows get the full radius.
        let radius = min(ScreenTranslate.windowCornerRadius, min(highlight.width, highlight.height) / 6)
        if highlight.width >= 2, highlight.height >= 2 {
            dim.append(NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()
        if highlight.width >= 2, highlight.height >= 2 {
            let outer = NSBezierPath(roundedRect: highlight.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            outer.lineWidth = 3
            NSColor.black.withAlphaComponent(0.35).setStroke()
            outer.stroke()
            let inner = NSBezierPath(roundedRect: highlight.insetBy(dx: 1.5, dy: 1.5), xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
            inner.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.92).setStroke()
            inner.stroke()
        }
        let prompt: String
        if dragging {
            prompt = title.isEmpty ? String(localized: "松开翻译") : "\(title)  ·  " + String(localized: "松开翻译")
        } else if hoverBounds != nil {
            prompt = title.isEmpty ? String(localized: "点击框住，拖动自选") : "\(title)  ·  " + String(localized: "点击框住，拖动自选")
        } else {
            prompt = title.isEmpty ? String(localized: "移到窗口上或拖动划选") : "\(title)  ·  " + String(localized: "移到窗口上或拖动划选")
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
