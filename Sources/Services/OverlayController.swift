import AppKit
import SwiftUI

struct LanguageSwitchNotice: Equatable {
    let id = UUID()
    let title: String
    let from: String
    let to: String
}

@MainActor
@Observable
final class OverlayModel {
    static let waveformSampleCount = 36

    var phase: OverlayPhase = .hidden
    var languageSwitch: LanguageSwitchNotice?
    var completion: CompletionFeedback?
    var sourceText = ""
    var translatedText = ""
    var statusText = ""
    var sourceLanguageName = ""
    var targetLanguageName = ""
    var hotkeyLabel = "右⌥"
    var liveInjectEnabled = true
    var level: Float = 0
    var levels: [Float] = Array(repeating: 0, count: OverlayModel.waveformSampleCount)
    var sweepID = 0
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var panel: OverlayPanel?
    private var smoothedLevel: Float = 0
    private var noticeTask: Task<Void, Never>?
    private let displaysPanel: Bool

    init(displaysPanel: Bool = true) { self.displaysPanel = displaysPanel }

    private func cancelNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        model.languageSwitch = nil
        model.completion = nil
    }

    func showLanguageSwitch(from: String, to: String, title: String = "", duration: Double = 1.5) {
        // A notification must never cover an active recording or finalization.
        guard model.phase == .hidden || model.languageSwitch != nil else { return }
        cancelNotice()
        let notice = LanguageSwitchNotice(title: title.isEmpty ? "\(from) → \(to)" : title, from: from, to: to)
        model.languageSwitch = notice
        present()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.model.languageSwitch?.id == notice.id else { return }
            // Hide synchronously. A window-alpha animation could outlive this
            // notice and accidentally fade a newer notice or recording waveform.
            self.model.languageSwitch = nil
            self.panel?.orderOut(nil)
            self.noticeTask = nil
        }
    }

    func showCompletion(_ feedback: CompletionFeedback, duration: Double? = nil) {
        guard feedback.isWarning else { return }
        cancelNotice()
        model.completion = feedback
        present()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration ?? 4)) } catch { return }
            guard let self else { return }
            self.hide()
        }
    }

    func showConversionFailure(duration: Double = 4) {
        guard model.phase == .hidden, model.completion == nil else { return }
        cancelNotice()
        model.phase = .error
        model.statusText = "转换失败 · 请重试或查看设置"
        present()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.hide()
        }
    }

    private func present() {
        prepare()
        guard let panel else { return }
        panel.reposition()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // HostingView's fitting size updates after the new SwiftUI content is applied.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.panel?.reposition()
        }
    }

    func prepare() {
        guard displaysPanel, panel == nil else { return }
        let panel = OverlayPanel(model: model)
        panel.alphaValue = 0
        panel.reposition()
        self.panel = panel
    }

    func setHotkeyLabel(_ label: String) {
        model.hotkeyLabel = label
    }

    func show(source: String, target: String, liveInject: Bool, hotkeyLabel: String) {
        cancelNotice()
        model.sourceLanguageName = source
        model.targetLanguageName = target
        model.liveInjectEnabled = liveInject
        model.hotkeyLabel = hotkeyLabel
        model.sourceText = ""
        model.translatedText = ""
        model.statusText = ""
        model.level = 0
        model.levels = Array(repeating: 0, count: OverlayModel.waveformSampleCount)
        model.phase = .preparing
        smoothedLevel = 0

        present()
    }

    func setPhase(_ phase: OverlayPhase, status: String = "") {
        cancelNotice()
        model.phase = phase
        model.statusText = status
        panel?.reposition()
    }

    func setSource(_ text: String) {
        model.sourceText = text
        panel?.reposition()
    }

    func setTranslation(_ text: String) {
        model.translatedText = text
        panel?.reposition()
    }

    func setLevel(_ level: Float) {
        let coefficient: Float = level > smoothedLevel ? 0.75 : 0.22
        smoothedLevel += (level - smoothedLevel) * coefficient
        model.level = smoothedLevel
        var samples = model.levels
        samples.removeFirst()
        samples.append(smoothedLevel)
        model.levels = samples
    }

    func hide() {
        cancelNotice()
        panel?.orderOut(nil)
        model.phase = .hidden
        model.sweepID = 0
    }

    /// Successful recognition: keep the HUD up for a light sweep, then close.
    func playFinishSweepThenHide() {
        if !displaysPanel || model.phase == .hidden || model.phase == .cancelling || model.phase == .error {
            hide()
            return
        }
        cancelNotice()
        model.sweepID += 1
        panel?.reposition()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(620)) } catch { return }
            self?.hide()
        }
    }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class OverlayPanel: NSPanel {
    private let glass = NSGlassEffectView()
    private let hosting: NSHostingView<OverlayView>

    init(model: OverlayModel) {
        let hosting = TransparentHostingView(rootView: OverlayView(model: model))
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true

        glass.style = .regular
        glass.cornerRadius = 28
        glass.contentView = hosting
        contentView = glass
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width <= 0 || size.height <= 0 {
            size = NSSize(width: 280, height: 56)
        }
        glass.cornerRadius = size.height / 2
        setContentSize(size)
        let x = visible.midX - size.width / 2
        let y = visible.minY + 28
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
