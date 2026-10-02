import AppKit
import QuartzCore

/// Optional full-screen shield that blocks pointer input to other apps while a pin
/// is visible. Off by default; the pin is meant to float like PixPin/CleanShot.
final class ScreenPinFreezePanel: NSPanel {
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

final class ScreenPinFreezeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)" ) }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func scrollWheel(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
}

final class ScreenPinPassThroughView: NSView {
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

final class ScreenPinBorderView: NSView {
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

final class ScreenPinCanvasView: NSView {
    private var sourceImage = NSImage()
    /// The capture with its text translated in place; drawn instead of the capture when set.
    private var translatedImage: NSImage?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// Dragging the captured image moves the whole pin, like a floating screenshot.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    func setSource(_ image: NSImage) {
        sourceImage = image
        translatedImage = nil
        frame = CGRect(origin: .zero, size: image.size)
        needsDisplay = true
    }

    func setTranslated(_ image: NSImage?) {
        translatedImage = image
        needsDisplay = true
    }

    var showsTranslation: Bool { translatedImage != nil }

    override func draw(_ dirtyRect: NSRect) {
        // Pixel for pixel: both pictures are the capture's own size, nothing is resampled.
        (translatedImage ?? sourceImage).draw(
            in: CGRect(origin: .zero, size: sourceImage.size),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none.rawValue]
        )
    }
}
