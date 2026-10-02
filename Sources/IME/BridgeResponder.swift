import Foundation

/// The input method's answers to the main program: decode a request, apply it
/// to the core, encode the reply. Kept apart from the process glue so the
/// whole exchange can run in a test without InputMethodKit.
@MainActor
struct BridgeResponder {
    let core: InputMethodCore
    var status: () -> BridgeIMEStatus
    var applyPinyin: (BridgePinyinPreferences) -> Void
    /// The main program introduced itself (or again): the host watches that process.
    var mainProgramSeen: (Int32) -> Void
    var trace: (String, String) -> Void = { _, _ in }

    func answer(_ data: Data) -> Data? {
        guard let request = Bridge.decode(BridgeRequest.self, from: data) else { return nil }
        switch request {
        case .status:
            return Bridge.encode(BridgeReply.status(status()))
        case .context(let context):
            mainProgramSeen(context.appPID)
            core.apply(context)
            return Bridge.encode(BridgeReply.done(true))
        case .pinyin(let preferences):
            applyPinyin(preferences)
            return Bridge.encode(BridgeReply.done(true))
        case .voiceMarked(let session, let seq, let text):
            return Bridge.encode(BridgeReply.done(core.voiceMarked(session: session, seq: seq, text: text)))
        case .voiceClear(let session):
            core.voiceClear(session: session)
            return Bridge.encode(BridgeReply.done(true))
        case .voiceInsert(let session, let text, let deadline):
            let written = core.voiceInsert(session: session, text: text, deadline: deadline)
            trace("voice-insert", written ? "written" : "refused")
            return Bridge.encode(BridgeReply.done(written))
        case .voiceEnd(let session):
            core.voiceEnd(session: session)
            return Bridge.encode(BridgeReply.done(true))
        case .voiceForget(let session):
            core.voiceForget(session: session)
            return Bridge.encode(BridgeReply.done(true))
        }
    }
}
