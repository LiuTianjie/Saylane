import Foundation

/// Reads a dictation back from the client it was written into, so the main
/// program can learn the names the user corrects afterwards. This process only
/// reads and reports: what a change means is decided in the main program,
/// where a mistake cannot take typing down. Nothing is read unless the main
/// program says the user allows it (`BridgeContext.learnsCorrections`), and
/// nothing is reported while the stretch still reads as it was written.
///
/// When the client is asked (one call per watched dictation each time):
/// - Half a second after the write, once. The stretch must read back exactly
///   as written; a client that cannot report its text, or reports something
///   else there, is not asked again about that dictation. Not at once:
///   Chromium answers from a copy that is filled a moment after the write.
/// - Before Return, Enter or Tab goes to the application. The next thing that
///   happens may be the message being sent and the field emptied.
/// - Three seconds after the last key. An edit is over when typing pauses, and
///   a message sent with the mouse leaves no other moment.
/// - When the next dictation starts in the same client, before its preview
///   stands in the text.
/// - When the client loses focus in an orderly way, while it can still answer.
/// Never while pinyin is composing (a composition is part of the client's
/// text) and never while a dictation is being written.
@MainActor
final class DictationReadBack {
    private struct Watch {
        let session: UUID
        let leaseID: UUID
        /// UTF-16 offset of the dictation in the client's text, and its length when written.
        let start: Int
        let length: Int
        let written: String
        let since: TimeInterval
        /// The client read the stretch back exactly as written.
        var verified = false
        /// What was last reported; nil while the stretch is untouched.
        var reported: String?
    }

    /// Dictations watched at once. They are the user's most recent ones in one client.
    static let limit = 3
    /// A dictation is watched this long. Offsets go stale as the text around it changes.
    static let lifetime: TimeInterval = 300
    /// UTF-16 units. A longer dictation is not watched: it would be a long read.
    static let longest = 600
    /// Read this far past the stretch: a correction may be longer than what it replaces.
    static let slack = 32
    static let settleDelay: TimeInterval = 0.5
    static let pauseDelay: TimeInterval = 3

    private let manager: IMEManager
    private let send: (BridgeEvent) -> Void
    private let now: () -> TimeInterval
    private let settle: InputDeferralDeadline
    private let pause: InputDeferralDeadline
    private let expiry: InputDeferralDeadline
    private var watches: [Watch] = []
    /// Nothing is being composed or dictated: the client's text is the user's.
    var isQuiet: () -> Bool = { true }
    /// Outcomes only, never text.
    var trace: (String, String) -> Void = { _, _ in }

    var isWatching: Bool { !watches.isEmpty }

    init(manager: IMEManager, send: @escaping (BridgeEvent) -> Void, now: @escaping () -> TimeInterval,
         sleep: @escaping (TimeInterval) async throws -> Void) {
        self.manager = manager
        self.send = send
        self.now = now
        settle = InputDeferralDeadline(sleep: sleep)
        pause = InputDeferralDeadline(sleep: sleep)
        expiry = InputDeferralDeadline(sleep: sleep)
    }

    // MARK: - What happens to a dictation

    /// A dictation was written at `point`.
    func wrote(_ text: String, session: UUID, at point: (leaseID: UUID, start: Int)) {
        expire()
        // Text written inside or before a watched stretch moves it: what is
        // read there afterwards is no longer that dictation.
        close { $0.leaseID != point.leaseID || point.start < $0.start + $0.length }
        let length = (text as NSString).length
        guard length > 0, length <= Self.longest else { return }
        if watches.count >= Self.limit { close(watches[0].session) }
        watches.append(Watch(session: session, leaseID: point.leaseID, start: point.start, length: length,
                             written: text, since: now()))
        settle.cancel()
        settle.arm(after: Self.settleDelay) { [weak self] in self?.settled() }
        // Without a key or a focus change nothing else would let go of the text when its time is up.
        expiry.cancel()
        expiry.arm(after: Self.lifetime + 1) { [weak self] in self?.expire() }
    }

    /// The client has had time to take the write in: does it read back?
    func settled() {
        for watch in watches where !watch.verified {
            let read = manager.readText(start: watch.start, length: watch.length, leaseID: watch.leaseID)
            if read == watch.written, let index = watches.firstIndex(where: { $0.session == watch.session }) {
                watches[index].verified = true
                trace("read-back", "watching")
            } else {
                trace("read-back", read == nil ? "the client does not report its text" : "the client reports other text")
                watches.removeAll { $0.session == watch.session }
            }
        }
    }

    /// A key went down in the client. `leaves`: it may send the text or move on from it.
    func keyDown(leaves: Bool) {
        guard isWatching else { return }
        if leaves, isQuiet() { read() }
        pause.cancel()
        pause.arm(after: Self.pauseDelay) { [weak self] in self?.typingPaused() }
    }

    func typingPaused() {
        guard isWatching, isQuiet() else { return }
        read()
    }

    /// Ask the client about every watched dictation and report the ones that changed.
    func read() {
        expire()
        for watch in watches where watch.verified { look(at: watch, closing: false) }
    }

    /// The lease loses its client. `readable`: the client can still be asked.
    func leaseEnding(_ leaseID: UUID, readable: Bool) {
        expire()
        let quiet = readable && isQuiet()
        for watch in watches where watch.leaseID == leaseID {
            if quiet, watch.verified { look(at: watch, closing: true) } else { close(watch.session) }
        }
    }

    /// The main program has what it needs, or the text is gone.
    func forget(_ session: UUID) {
        watches.removeAll { $0.session == session }
    }

    /// Learning was switched off, or the main program is gone: nobody is listening.
    func reset() {
        settle.cancel()
        pause.cancel()
        expiry.cancel()
        watches.removeAll()
    }

    // MARK: - Reading

    private func look(at watch: Watch, closing: Bool) {
        let window = watch.length + Self.slack
        var text = manager.readText(start: watch.start, length: window, leaseID: watch.leaseID)
        // A client that gives back less than it was asked for has no more text.
        var ends = text.map { ($0 as NSString).length < window } ?? false
        if text == nil {
            // Some clients answer only for a range that lies wholly inside their text.
            text = manager.readText(start: watch.start, length: watch.length, leaseID: watch.leaseID)
            ends = false
        }
        guard let text else {
            trace("read-back", "the client stopped reporting its text")
            close(watch.session)
            return
        }
        let untouched = watch.reported == nil && text.hasPrefix(watch.written)
        if untouched || text == watch.reported {
            if closing { close(watch.session) }
            return
        }
        // Something else stands there now: the message was sent, the field
        // emptied, another field of the same client has the focus. That text
        // is not this dictation's and is passed on to nobody.
        guard Self.resembles(text, watch.written) else {
            trace("read-back", "the text is gone")
            close(watch.session)
            return
        }
        if let index = watches.firstIndex(where: { $0.session == watch.session }) { watches[index].reported = text }
        trace("read-back", closing ? "reported a change and closed" : "reported a change")
        send(.readBack(BridgeReadBack(session: watch.session, text: text, startsDocument: watch.start == 0,
                                      endsDocument: ends, closed: closing)))
        if closing { watches.removeAll { $0.session == watch.session } }
    }

    /// Whether what stands there can still be the dictation, edited: a third
    /// of its letters are still present. Crude on purpose; what an edit means
    /// is the main program's judgment.
    private static func resembles(_ text: String, _ written: String) -> Bool {
        func letters(_ string: String) -> Set<Unicode.Scalar> {
            Set(string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let before = letters(written)
        return !before.isEmpty && before.intersection(letters(text)).count * 3 >= before.count
    }

    private func expire() {
        let time = now()
        close { time - $0.since > Self.lifetime }
    }

    private func close(where ended: (Watch) -> Bool) {
        for watch in watches where ended(watch) { close(watch.session) }
    }

    /// Stop watching. The main program hears about it only when it was told of a change.
    private func close(_ session: UUID) {
        guard let index = watches.firstIndex(where: { $0.session == session }) else { return }
        if watches[index].reported != nil {
            send(.readBack(BridgeReadBack(session: session, text: nil, closed: true)))
        }
        watches.remove(at: index)
    }
}
