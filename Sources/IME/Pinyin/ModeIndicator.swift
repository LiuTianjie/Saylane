import AppKit
import SwiftUI

/// A small 中 or 英 next to the caret for a moment after the typing mode
/// changes, so a switch never goes unnoticed. It takes no clicks and no focus.
@MainActor
final class ModeIndicator {
    private var panel: NSPanel?
    private let model = ModeIndicatorModel()
    private var hideWork: DispatchWorkItem?
    private static let visibleFor: TimeInterval = 0.9

    func show(english: Bool, caret: NSRect?) {
        model.english = english
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 32, height: 32)
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: size, caret: caret))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel?.alphaValue == 0 else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: ModeIndicatorView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    /// Just below and right of the caret; next to the pointer when the client reports no caret.
    private static func origin(for size: NSSize, caret: NSRect?) -> NSPoint {
        let anchor: NSRect
        if let caret, caret.width + caret.height > 0 {
            anchor = caret
        } else {
            let mouse = NSEvent.mouseLocation
            anchor = NSRect(x: mouse.x + 8, y: mouse.y - 4, width: 1, height: 18)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        var origin = NSPoint(x: anchor.maxX + 4, y: anchor.minY - size.height - 4)
        if origin.y < visible.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return origin
    }
}

@MainActor @Observable
final class ModeIndicatorModel {
    var english = false
}

private struct ModeIndicatorView: View {
    let model: ModeIndicatorModel

    var body: some View {
        Text(model.english ? "英" : "中")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(model.english ? Color.primary : Theme.accent)
            .frame(width: 30, height: 30)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .accessibilityLabel(model.english ? String(localized: "英文") : String(localized: "中文"))
    }
}
