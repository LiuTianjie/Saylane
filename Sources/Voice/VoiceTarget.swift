import Foundation

/// How a finished dictation reached the user.
enum VoiceDelivery: Equatable, Sendable {
    /// Inserted through the attached input-method client.
    case inputMethod
    /// Pasted at the caret of the frontmost application.
    case pasted
    /// Nothing could be written; the text is on the pasteboard.
    case copied
    /// Another application came to the front; the text is on the pasteboard.
    case copiedAfterAppSwitch
    /// A key or a click cut the dictation short; the text is on the pasteboard.
    case copiedAfterInterrupt
}

/// The ways a dictation can be written, as closures so tests need no input
/// method, event posting or pasteboard.
@MainActor
struct VoiceTextSink {
    /// The input method is attached to a client of the application right now.
    var attached: () -> Bool = { false }
    /// Live preview at the caret, through the input method. False when it is not attached.
    var setMarked: (String) -> Bool
    var clearMarked: () -> Void
    /// Insert through the input method. False when it is not attached or did not answer.
    var insert: (String) -> Bool
    /// Paste at the caret. False when key events cannot be posted.
    var paste: (String) -> Bool
    var copy: (String) -> Void
    /// The dictation is over, written or not: the input method stops waiting for it.
    var end: () -> Void = {}
}

/// A dictation belongs to the application that had the keyboard at the press, not
/// to one text field or one IMK activation. Previews follow the IMK client when
/// there is one; the final text lands at that application's caret through the
/// first route that works. It is never written into another application and
/// never dropped: when nothing can take it, it is left on the pasteboard.
@MainActor
final class FocusedTextTarget: CompositionTarget {
    private let sink: VoiceTextSink
    private let stillInFront: () -> Bool
    private var showsMarked = false
    /// The dictation was cut short by a key or a click: where the caret is now
    /// is not where it was meant to go.
    var interrupted = false
    var onDelivery: ((VoiceDelivery, String) -> Void)?

    init(sink: VoiceTextSink, stillInFront: @escaping () -> Bool) {
        self.sink = sink
        self.stillInFront = stillInFront
    }

    /// Losing the field or the application changes the route, not the session.
    var isValid: Bool { true }

    func setMarked(_ text: String) {
        showsMarked = sink.setMarked(text)
    }

    func commit(_ text: String) {
        guard stillInFront(), !interrupted else {
            cancelMarked()
            sink.copy(text)
            onDelivery?(interrupted ? .copiedAfterInterrupt : .copiedAfterAppSwitch, text)
            return
        }
        if sink.insert(text) {
            // `insertText` replaces the marked preview.
            showsMarked = false
            onDelivery?(.inputMethod, text)
            return
        }
        cancelMarked()
        if sink.paste(text) {
            onDelivery?(.pasted, text)
            return
        }
        sink.copy(text)
        onDelivery?(.copied, text)
    }

    func cancelMarked() {
        guard showsMarked else { return }
        showsMarked = false
        sink.clearMarked()
    }
}
