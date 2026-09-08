import AppKit
import SwiftUI

@MainActor
final class CandidateWindowController {
    private var panel: CandidatePanel?
    private let model = CandidateBarModel()

    private var lastCandidates: [PinyinCandidate] = []
    private var lastHighlight = 0
    private var lastCaret: NSRect?
    private var lastPreedit = ""
    private var lastAssociating = false

    func update(candidates: [PinyinCandidate], highlight: Int, caret: NSRect?,
                preedit: String = "", associating: Bool = false) {
        lastCandidates = candidates
        lastHighlight = highlight
        lastCaret = caret
        lastPreedit = preedit
        lastAssociating = associating
        render()
    }

    private func render() {
        let candidates = lastCandidates
        guard !candidates.isEmpty else { hide(); return }
        let pageSize = PinyinSession.pageSize
        let page = lastHighlight / pageSize
        let start = page * pageSize
        let visible = model.expanded ? pageSize * 2 : pageSize
        let end = min(start + visible, candidates.count)
        let items = Array(candidates[start..<end])
        model.items = items
        model.selected = lastHighlight - start
        model.pageIndex = page
        model.pageCount = max(1, (candidates.count + pageSize - 1) / pageSize)
        model.preedit = lastPreedit
        model.associating = lastAssociating
        model.canExpand = candidates.count > pageSize
        prepare()
        panel?.onPick = { [weak self] local in
            self?.model.onCommit?(start + local)
        }
        panel?.onPage = { [weak self] delta in
            self?.model.onPage?(delta)
        }
        panel?.onToggleExpand = { [weak self] in
            guard let self else { return }
            self.model.expanded.toggle()
            self.render()
        }
        panel?.reposition(caret: lastCaret)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    func setOnPick(_ handler: @escaping (Int) -> Void) {
        model.onCommit = handler
    }

    func setOnPage(_ handler: @escaping (Int) -> Void) {
        model.onPage = handler
    }

    func hide() {
        panel?.orderOut(nil)
        model.items = []
        model.preedit = ""
        model.associating = false
        model.expanded = false
        model.canExpand = false
        lastCandidates = []
    }

    private func prepare() {
        guard panel == nil else { return }
        let panel = CandidatePanel(model: model)
        panel.alphaValue = 0
        self.panel = panel
    }
}

@MainActor
@Observable
final class CandidateBarModel {
    var items: [PinyinCandidate] = []
    var selected = 0
    var pageIndex = 0
    var pageCount = 1
    var preedit = ""
    var associating = false
    var expanded = false
    var canExpand = false
    var onCommit: ((Int) -> Void)?
    var onPage: ((Int) -> Void)?
}

final class CandidatePanel: NSPanel {
    var onPick: ((Int) -> Void)?
    var onPage: ((Int) -> Void)?
    var onToggleExpand: (() -> Void)?
    private let model: CandidateBarModel

    init(model: CandidateBarModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        let hosting = NSHostingView(rootView: CandidateBarHost(model: model, onPick: { [weak self] index in
            self?.onPick?(index)
        }, onPage: { [weak self] delta in
            self?.onPage?(delta)
        }, onToggleExpand: { [weak self] in
            self?.onToggleExpand?()
        }))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(caret: NSRect?) {
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? NSSize(width: 420, height: 48)
        guard size.width > 0, size.height > 0 else { return }
        setContentSize(size)
        let screen = NSScreen.screens.first { screen in caret.map { screen.frame.intersects($0) } ?? false }
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 800, height: 600)
        var origin = NSPoint(x: visible.minX + 24, y: visible.minY + 80)
        if let caret, caret.width + caret.height > 0 {
            origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 8)
            if origin.y < visible.minY {
                origin.y = caret.maxY + 8
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }
}

private struct CandidateBarHost: View {
    @Bindable var model: CandidateBarModel
    var onPick: (Int) -> Void
    var onPage: (Int) -> Void
    var onToggleExpand: () -> Void

    var body: some View {
        CandidateBarView(items: model.items, selected: model.selected, pageIndex: model.pageIndex,
                         pageCount: model.pageCount, preedit: model.preedit, associating: model.associating,
                         expanded: model.expanded, canExpand: model.canExpand,
                         onPick: onPick, onPage: onPage, onToggleExpand: onToggleExpand)
    }
}
