import AppKit

/// Writes into a text view of this process. Our own windows are ordinary
/// clients of the input method; this is the route that needs nobody else.
@MainActor
enum LocalTextInserter {
    static func insert(_ text: String) -> Bool {
        guard NSApp.isActive, let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable else { return false }
        view.insertText(text, replacementRange: view.selectedRange())
        return true
    }
}
