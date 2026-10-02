import AppKit

/// The pinned capture and, over it, the same picture with the text
/// translated in place: a floating, draggable, non-activating panel. It never brings the input-method host to the front.
final class ScreenPinPanel: NSPanel, NSWindowDelegate {
    var onToggleOverlay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onCycle: (() -> Void)?
    /// Install full-screen shields that block pointer input to other apps.
    var freezesScreen = false
    private var fullTextPopover: NSPopover?
    var hasTranslationDetail: Bool { fullTextPopover?.isShown == true }
    @discardableResult func closeTranslationDetail() -> Bool {
        let wasOpen = hasTranslationDetail
        fullTextPopover?.close()
        return wasOpen
    }
    private(set) var canvasSize = CGSize.zero
    private let model: ScreenPinModel
    private let chrome: ScreenPinChromePanel
    private let card = NSView()
    private let scrollView = NSScrollView()
    private let canvasView = ScreenPinCanvasView()
    private let borderView = ScreenPinBorderView()
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
        canvasView.setSource(source)
        layoutCard(size: rect.size)
        refreshChrome()
        if freezesScreen { installFreezePanels() }
        orderFrontRegardless()
        chrome.orderFrontRegardless()
        // The pin's keys belong to it from the moment it appears: ⌘C right after a
        // translation copies the picture. Left to the application in front, ⌘C
        // copied whatever text was selected there (seen on device with 0.7.0).
        // The panel does not activate this program; a click anywhere else gives the keys back.
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

    /// The translated picture, the size of the capture; nil while there is none.
    /// With the overlay off the capture itself is shown.
    func show(translated: NSImage?, overlayEnabled: Bool) {
        canvasView.setTranslated(overlayEnabled ? translated : nil)
        refreshChrome()
    }

    #if DEBUG
    /// What the pin shows, as a picture.
    func snapshot() -> NSBitmapImageRep? {
        guard let view = contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    #endif

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
