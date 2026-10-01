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
    private var scrollOffsets: [String: CGFloat] = [:]

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

final class ScreenPinBlockView: NSView {
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
            ? item.text + "\n\n" + String(localized: "点击展开，或在这段文字内滚动") : nil
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

final class ScreenPinTextView: NSView {
    var item: ScreenLaidOutBlock?
    var onExpand: (() -> Void)?
    var canExpand = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func resetCursorRects() {
        if canExpand { addCursorRect(visibleRect, cursor: .pointingHand) }
    }
    override func mouseDown(with event: NSEvent) {
        if canExpand { onExpand?() } else { window?.performDrag(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ScreenPinRenderer.drawInk(item, in: context, visibleRange: visibleRect.minY...visibleRect.maxY)
    }
}

final class ScreenTranslationDetailController: NSViewController {
    private let text: String
    init(text: String) { self.text = text; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func loadView() {
        let width: CGFloat = 360
        let height = min(400, max(90, ScreenTranslate.textHeight(text: text, fontSize: 15,
            width: width - 32, heading: false) + 20))
        view = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height + 52))
        let title = NSTextField(labelWithString: String(localized: "完整译文"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 16, y: height + 18, width: 190, height: 18)
        view.addSubview(title)
        let copy = NSButton(title: String(localized: "复制文字"), target: self, action: #selector(copyText))
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
