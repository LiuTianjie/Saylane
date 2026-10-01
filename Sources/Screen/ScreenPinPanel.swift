import AppKit

/// The pinned capture with its translation overlay: a floating, draggable,
/// non-activating panel. It never brings the input-method host to the front.
final class ScreenPinPanel: NSPanel, NSWindowDelegate {
    var onToggleOverlay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onCycle: (() -> Void)?
    /// Install full-screen shields that block pointer input to other apps.
    var freezesScreen = false
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
        isMovableByWindowBackground = true
        isMovable = true
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
        addChildWindow(chrome, ordered: .above)
        delegate = self
    }

    /// Key so its own keys (Esc, Tab, ⌘C) work once clicked; `.nonactivatingPanel`
    /// keeps the host app in the background.
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
        if freezesScreen { installFreezePanels() }
        orderFrontRegardless()
        chrome.orderFrontRegardless()
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

    /// The user dragged the pin: keep the toolbar attached to its new place.
    func windowDidMove(_ notification: Notification) { followMove() }

    private func followMove() {
        let moved = frame.insetBy(dx: glowPad, dy: glowPad)
        guard moved != displayRect else { return }
        displayRect = moved
        pinRect = moved
        refreshChrome()
    }

    private func installFreezePanels() {
        guard freezePanels.isEmpty else { return }
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
