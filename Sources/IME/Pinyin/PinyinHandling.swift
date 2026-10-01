import AppKit

/// What the input method's core needs from the pinyin engine; a fake stands in for tests.
@MainActor
protocol PinyinHandling: AnyObject {
    var isComposing: Bool { get }
    func ensureClient(_ key: UUID?)
    func handle(_ event: NSEvent, pushToTalk: PushToTalkHotkey) -> Bool
    func commit()
}
