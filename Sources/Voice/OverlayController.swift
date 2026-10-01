import AppKit
import CoreGraphics
import SwiftUI

/// The screen facts needed to choose a HUD target. Keeping the policy independent
/// from `NSScreen` makes multi-display behavior deterministic and testable without
/// presenting a window.
struct OverlayScreenDescriptor: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let isMain: Bool
}

enum OverlayScreenSelector {
    static func choose(
        from screens: [OverlayScreenDescriptor],
        caretRect: CGRect?,
        frontmostWindowRect: CGRect?,
        mouseLocation: CGPoint
    ) -> OverlayScreenDescriptor? {
        guard !screens.isEmpty else { return nil }
        if let caretRect, isUsable(caretRect), let screen = screen(containing: caretRect, in: screens) {
            return screen
        }
        if let frontmostWindowRect, isUsable(frontmostWindowRect),
           let screen = screen(containing: frontmostWindowRect, in: screens) {
            return screen
        }
        return screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? screens.first(where: \.isMain)
            ?? screens.first
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 0 && rect.height >= 0
            && rect.width + rect.height > 0
    }

    private static func screen(
        containing rect: CGRect,
        in screens: [OverlayScreenDescriptor]
    ) -> OverlayScreenDescriptor? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let containing = screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        return screens
            .map { screen -> (screen: OverlayScreenDescriptor, area: CGFloat) in
                let overlap = screen.frame.intersection(rect)
                let area: CGFloat = overlap.isNull ? 0 : overlap.width * overlap.height
                return (screen, area)
            }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?
            .screen
    }
}

/// A presentation chooses its target once. Resizing the HUD for a phase or text
/// update resolves this stored ID instead of consulting the current mouse screen.
struct OverlayScreenTarget {
    private(set) var displayID: CGDirectDisplayID?

    mutating func begin(
        screens: [OverlayScreenDescriptor],
        caretRect: CGRect?,
        frontmostWindowRect: CGRect?,
        mouseLocation: CGPoint
    ) {
        displayID = OverlayScreenSelector.choose(
            from: screens,
            caretRect: caretRect,
            frontmostWindowRect: frontmostWindowRect,
            mouseLocation: mouseLocation
        )?.displayID
    }

    func resolve(in screens: [OverlayScreenDescriptor]) -> OverlayScreenDescriptor? {
        if let displayID, let exact = screens.first(where: { $0.displayID == displayID }) {
            return exact
        }
        return screens.first(where: \.isMain) ?? screens.first
    }

    mutating func end() { displayID = nil }
}

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
    var statusText = ""
    var sourceLanguageName = ""
    var targetLanguageName = ""
    var hotkeyLabel = String(localized: "右⌥")
    var liveInjectEnabled = true
    /// A transient message shown in place of the waveform.
    var notice: String?
    var noticeIsWarning = false
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
        model.notice = nil
    }

    /// Show a `UserNotice` message. Never covers an active session; shown after it ends instead.
    func showNotice(_ message: String, warning: Bool, duration: Double) {
        guard duration > 0 else { return }
        guard model.phase == .hidden || model.phase == .error else { return }
        cancelNotice()
        model.phase = .error
        model.notice = message
        model.noticeIsWarning = warning
        model.statusText = message
        present(renewTarget: true)
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.hide()
        }
    }

    func showLanguageSwitch(from: String, to: String, title: String = "", duration: Double = 1.5) {
        // A notification must never cover an active recording or finalization.
        guard model.phase == .hidden || model.languageSwitch != nil else { return }
        let continuesCurrentPresentation = model.languageSwitch != nil
        cancelNotice()
        let notice = LanguageSwitchNotice(title: title.isEmpty ? "\(from) → \(to)" : title, from: from, to: to)
        model.languageSwitch = notice
        present(renewTarget: !continuesCurrentPresentation)
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.model.languageSwitch?.id == notice.id else { return }
            // Hide synchronously. A window-alpha animation could outlive this
            // notice and accidentally fade a newer notice or recording waveform.
            self.model.languageSwitch = nil
            self.panel?.orderOut(nil)
            self.panel?.endPresentation()
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
        model.noticeIsWarning = true
        model.statusText = String(localized: "转换失败 · 请重试或查看设置")
        present(renewTarget: true)
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.hide()
        }
    }

    private func present(caretRect: NSRect? = nil, renewTarget: Bool = false) {
        prepare()
        guard let panel else { return }
        if renewTarget { panel.beginPresentation(caretRect: caretRect) }
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
        self.panel = panel
    }

    func setHotkeyLabel(_ label: String) {
        model.hotkeyLabel = label
    }

    /// Start one HUD session and lock it to a display. The voice/IME boundary may
    /// inject the active caret rectangle; callers without one still get the
    /// frontmost-window and pointer fallbacks.
    func show(
        source: String,
        target: String,
        liveInject: Bool,
        hotkeyLabel: String,
        caretRect: NSRect? = nil
    ) {
        cancelNotice()
        model.sourceLanguageName = source
        model.targetLanguageName = target
        model.liveInjectEnabled = liveInject
        model.hotkeyLabel = hotkeyLabel
        model.statusText = ""
        model.level = 0
        model.levels = Array(repeating: 0, count: OverlayModel.waveformSampleCount)
        model.phase = .preparing
        smoothedLevel = 0

        present(caretRect: caretRect, renewTarget: true)
    }

    func setPhase(_ phase: OverlayPhase, status: String = "") {
        cancelNotice()
        model.phase = phase
        model.statusText = status
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
        panel?.endPresentation()
        model.phase = .hidden
        model.sweepID = 0
        model.statusText = ""
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
    private var targetScreen = OverlayScreenTarget()
    /// Registered and removed on the main thread; Objective-C's observer token is
    /// not annotated Sendable, so make that ownership contract explicit for deinit.
    nonisolated(unsafe) private var screenParametersObserver: NSObjectProtocol?

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

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.targetScreen.displayID != nil else { return }
                self.reposition()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func beginPresentation(caretRect: NSRect?) {
        let screens = Self.screenDescriptors()
        targetScreen.begin(
            screens: screens,
            caretRect: caretRect,
            frontmostWindowRect: Self.frontmostWindowRect(screens: screens),
            mouseLocation: NSEvent.mouseLocation
        )
    }

    func endPresentation() { targetScreen.end() }

    func reposition() {
        let screens = Self.screenDescriptors()
        if targetScreen.displayID == nil { beginPresentation(caretRect: nil) }
        guard let visible = targetScreen.resolve(in: screens)?.visibleFrame else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width <= 0 || size.height <= 0 {
            size = NSSize(width: 280, height: 56)
        }
        glass.cornerRadius = min(28, size.height / 2)
        setContentSize(size)
        let x = visible.midX - size.width / 2
        let y = visible.minY + 28
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func screenDescriptors() -> [OverlayScreenDescriptor] {
        let mainID = NSScreen.main.map(displayID)
        return NSScreen.screens.map { screen in
            let id = displayID(screen)
            return OverlayScreenDescriptor(
                displayID: id,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: id == mainID
            )
        }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        if let id = screen.deviceDescription[key] as? CGDirectDisplayID {
            return id
        }
        return CGMainDisplayID()
    }

    /// Front-to-back Core Graphics window metadata is available without activating
    /// the target application. It gives global top-left coordinates, converted here
    /// to AppKit's global bottom-left coordinates.
    private static func frontmostWindowRect(screens: [OverlayScreenDescriptor]) -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return nil }
        let mainHeight = screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        for item in windows {
            let ownerPID = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                ?? (item[kCGWindowOwnerPID as String] as? pid_t)
                ?? 0
            guard ownerPID == pid else { continue }
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (item[kCGWindowLayer as String] as? Int)
                ?? 0
            guard layer == 0 else { continue }
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
                ?? (item[kCGWindowAlpha as String] as? Double)
                ?? 1
            guard alpha > 0.05,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 1, height > 1 else { continue }
            return CGRect(x: x, y: mainHeight - y - height, width: width, height: height)
        }
        return nil
    }
}
