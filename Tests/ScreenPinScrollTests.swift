// Appended to the production private pin views by test-screen-scroll.sh.
@main struct ScreenPinScrollTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let size = CGSize(width: 420, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let panel = ScreenPinPanel(model: ScreenPinModel())
        panel.present(source: image, at: CGRect(x: 120, y: 240, width: size.width, height: size.height))
        defer { panel.orderOut(nil) }
        let fixedFrame = panel.frame
        let paragraphs = [ScreenParagraph(original: "A long paragraph", translation: String(repeating: "译文应该保持字号并完整向下展开。", count: 90),
            visionBox: CGRect(x: 0.05, y: 0.7, width: 0.9, height: 0.08),
            lineHeight: 0.08, linePitch: 0.08, isHeading: false, lineCount: 1)]
        let items = ScreenTranslate.layoutPlates(paragraphs, canvasSize: size)
        panel.updateOverlay(items: items, overlayEnabled: true)
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { findScroll($0) }.first
        }
        let scroll = findScroll(panel.contentView!)!
        let canvas = scroll.documentView!
        let textScroll = canvas.subviews.compactMap { findScroll($0) }.first!
        let document = textScroll.documentView!
        precondition(panel.frame == fixedFrame, "Growing content cannot resize the selected viewport")
        precondition(document.frame.height > size.height * 2 && textScroll.hasVerticalScroller)
        precondition(textScroll.contentView.bounds.minY == 0, "Translation starts at the top")
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0)!
        document.scrollWheel(with: NSEvent(cgEvent: event)!)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        precondition(textScroll.contentView.bounds.minY > 0, "Wheel input reaches the enclosing native scroll view")
        let position = textScroll.contentView.bounds.minY
        panel.updateOverlay(items: items, overlayEnabled: true)
        precondition(abs(textScroll.contentView.bounds.minY - position) < 1, "Progressive updates preserve the scroll position")
        precondition(canvas.frame.size == size, "Source geometry stays fixed even with long translations")
        panel.updateOverlay(items: items, overlayEnabled: false)
        precondition(canvas.frame.size == size && canvas.subviews.isEmpty, "Original mode restores source geometry")
        panel.updateOverlay(items: items, overlayEnabled: true)
        let restoredScroll = canvas.subviews.compactMap { findScroll($0) }.first!
        let restoredDocument = restoredScroll.documentView!
        precondition(abs(restoredScroll.contentView.bounds.minY - position) < 1, "Returning from source restores block scroll position")
        let maxY = restoredDocument.frame.height - restoredScroll.contentView.bounds.height
        restoredScroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        restoredScroll.reflectScrolledClipView(restoredScroll.contentView)
        precondition(abs(restoredScroll.contentView.bounds.maxY - restoredDocument.frame.height) < 1, "The full translation bottom is reachable inside its own block")
        if CommandLine.arguments.count > 1, let large = NSImage(contentsOfFile: CommandLine.arguments[1]),
           let pixels = large.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            large.size = CGSize(width: pixels.width / 2, height: pixels.height / 2)
            var benchmarkItems: [ScreenLaidOutBlock] = []
            for index in 0..<100 {
                let rect = CGRect(x: CGFloat(20 + (index % 4) * 500),
                    y: CGFloat(20 + (index / 4) * 50), width: 400, height: 28)
                benchmarkItems.append(ScreenLaidOutBlock(text: "原位翻译保持背景完整", rect: rect,
                    fontSize: 18, linePitch: 24, isHeading: false))
            }
            let many = ScreenTranslate.expandAndStack(benchmarkItems)
            let start = CFAbsoluteTimeGetCurrent()
            let prepared = ScreenPinRenderer.prepareItems(many, image: pixels, canvasSize: large.size)
            let sampled = CFAbsoluteTimeGetCurrent()
            let canvas = ScreenPinCanvasView()
            canvas.setSource(large)
            canvas.update(items: prepared, blurredImage: nil, canvasSize: large.size)
            let first = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 { canvas.update(items: prepared, blurredImage: nil, canvasSize: large.size) }
            let updated = CFAbsoluteTimeGetCurrent()
            print(String(format: "5K / 100 blocks: source sampling %.1f ms, first native update %.1f ms, cached update %.1f ms",
                (sampled - start) * 1000, (first - sampled) * 1000, (updated - first) * 200))
        }
        print("PASS: fixed source viewport, per-block wheel scrolling, progressive updates, source toggle, and bottom reachability")
    }
}
