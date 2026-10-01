import AppKit
import SwiftUI

/// The small toolbar under a pin: original/translation toggle, direction, status, copy, close.
final class ScreenPinChromePanel: NSPanel {
    var onToggleOverlay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRead: (() -> Void)?
    var onClose: (() -> Void)?
    var onCycle: (() -> Void)?
    private let model: ScreenPinModel
    private let hosting: NSHostingView<ScreenPinChromeView>

    init(model: ScreenPinModel) {
        self.model = model
        hosting = TransparentPinView(rootView: ScreenPinChromeView(
            model: model, onToggle: {}, onCopy: {}, onRead: {}, onClose: {}, onCycle: {}
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
            onCycle: { [weak self] in self?.onCycle?() }
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

struct ScreenPinChromeView: View {
    @Bindable var model: ScreenPinModel
    var onToggle: () -> Void
    var onCopy: () -> Void
    var onRead: () -> Void
    var onClose: () -> Void
    var onCycle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Text(model.overlayEnabled ? String(localized: "译文") : String(localized: "原文"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(model.overlayEnabled ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(String(localized: "切换原文 / 译文（Tab）"))
            Button(action: onCycle) {
                Text(model.directionTitle)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help(String(localized: "切换这块的翻译方向，不影响说话（D）"))
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            Button(String(localized: "复制"), action: onCopy)
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .help(String(localized: "复制图片并关闭（⌘C）"))
            if !model.fullText.isEmpty {
                Button(String(localized: "全文"), action: onRead)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .help(String(localized: "阅读并复制完整译文"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(String(localized: "关闭（Esc）"))
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

final class TransparentPinView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
