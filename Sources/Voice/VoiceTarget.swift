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
}

/// The ways a dictation can be written, as closures so tests need no IMK
/// client, event posting or pasteboard.
@MainActor
struct VoiceTextSink {
    /// Live preview in the attached IMK client. False when there is none.
    var setMarked: (String) -> Bool
    var clearMarked: () -> Void
    /// Insert through the attached IMK client. False when there is none.
    var insert: (String) -> Bool
    /// Paste at the caret. False when key events cannot be posted.
    var paste: (String) -> Bool
    var copy: (String) -> Void
}

/// A dictation belongs to the application that was in front at the press, not
/// to one text field or one IMK activation. Previews follow the IMK client when
/// there is one; the final text lands at that application's caret through the
/// first route that works. It is never written into another application and
/// never dropped: when nothing can take it, it is left on the pasteboard.
@MainActor
final class FocusedTextTarget: CompositionTarget {
    private let sink: VoiceTextSink
    private let stillInFront: () -> Bool
    private var showsMarked = false
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
        guard stillInFront() else {
            cancelMarked()
            sink.copy(text)
            onDelivery?(.copiedAfterAppSwitch, text)
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
