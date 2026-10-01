import AppKit

/// A real AppKit input client for manual/computer-use integration checks. It
/// never registers/enables an input source, requests permissions, or injects
/// events into another app. Drive its fields with ordinary keyboard input.
@MainActor private final class InputView: NSTextView {
    var onFocus: (() -> Void)?
    var onInput: (() -> Void)?
    private(set) var markedUpdates = 0
    private(set) var insertions = 0
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedUpdates += 1
        super.setMarkedText(value, selectedRange: selectedRange, replacementRange: replacementRange)
        onInput?()
    }
    override func insertText(_ value: Any, replacementRange: NSRange) {
        insertions += 1
        super.insertText(value, replacementRange: replacementRange)
        onInput?()
    }
}

@MainActor private final class Host: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var fields: [InputView] = []
    private var focused = 0
    private var originalSource: String?
    private let status = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 220, width: 680, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Saylane — native input integration"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        for index in 0..<2 {
            let label = NSTextField(labelWithString: "Input \(index + 1)")
            label.frame = NSRect(x: 20, y: 374 - index * 164, width: 620, height: 24)
            content.addSubview(label)
            let field = InputView(frame: NSRect(x: 20, y: 254 - index * 164, width: 640, height: 118))
            field.isRichText = false
            field.font = .systemFont(ofSize: 20)
            field.setAccessibilityLabel("Input \(index + 1)")
            field.onFocus = { [weak self] in self?.focused = index; self?.refreshStatus() }
            field.onInput = { [weak self] in self?.refreshStatus() }
            fields.append(field)
            content.addSubview(field)
        }
        let saylane = NSButton(title: "Select Saylane", target: self, action: #selector(selectSaylane))
        saylane.frame = NSRect(x: 20, y: 42, width: 160, height: 32)
        content.addSubview(saylane)
        let abc = NSButton(title: "Select ABC", target: self, action: #selector(selectABC))
        abc.frame = NSRect(x: 190, y: 42, width: 160, height: 32)
        content.addSubview(abc)
        status.frame = NSRect(x: 20, y: 10, width: 640, height: 25)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.addSubview(status)
        originalSource = fields[0].inputContext?.selectedKeyboardInputSource
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(fields[0])
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus()
    }

    @objc private func selectSaylane() { select("com.rtranslate.inputmethod.rtranslate.voice") }
    @objc private func selectABC() { select("com.apple.keylayout.ABC") }
    private func select(_ id: String) {
        let field = fields[focused]
        window.makeFirstResponder(field)
        guard let context = field.inputContext, context.keyboardInputSources?.contains(id) == true else {
            status.stringValue = "Source is not enabled; use the system Input Sources settings."
            return
        }
        context.selectedKeyboardInputSource = id
        refreshStatus()
    }
    private func refreshStatus() {
        guard fields.indices.contains(focused) else { return }
        let field = fields[focused]
        status.stringValue = "field=\(focused + 1) marked updates=\(field.markedUpdates) insertions=\(field.insertions) source=\(field.inputContext?.selectedKeyboardInputSource ?? "none")"
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        if let originalSource { fields[focused].inputContext?.selectedKeyboardInputSource = originalSource }
    }
}

@main private enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let host = Host()
        app.delegate = host
        withExtendedLifetime(host) { app.run() }
    }
}
