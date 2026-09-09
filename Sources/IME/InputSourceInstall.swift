import AppKit
import Carbon
import Foundation

/// File placement, TIS discovery, enablement, and selection are distinct states.
/// In particular, a mode's default-enabled flag is not proof its parent is enabled.
enum InputSourceInstall {
    static var lastFailure: String?
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.rtranslate.inputmethod.rtranslate" }
    static var modeID: String { bundleID + ".voice" }
    static var isInstalledLocation: Bool {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let allowed = [URL(fileURLWithPath: "/Library/Input Methods"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods")]
        return allowed.contains { $0.standardizedFileURL.resolvingSymlinksInPath() == parent }
    }
    @discardableResult
    static func registerBundle() -> OSStatus {
        lastFailure = nil
        guard isInstalledLocation else {
            lastFailure = "当前是未安装的构建副本，不能注册为输入法。"
            return OSStatus(paramErr)
        }
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        NSLog("Saylane: register status=%d path=%@", status, Bundle.main.bundlePath)
        if status != noErr { lastFailure = "系统输入法注册失败（错误码 \(status)）。" }
        return status
    }

    /// Issue enable requests from the running GUI app, not a short-lived installer process.
    /// The caller must allow time for system approval and re-read fresh TIS objects.
    static func requestEnable() -> Bool {
        guard registerBundle() == noErr else { return false }
        guard let parent = parentSource else {
            lastFailure = "文件已安装，但系统尚未发现输入法组件。不能开始语音输入。"
            return false
        }
        if !bool(parent, kTISPropertyInputSourceIsEnabled) {
            let status = TISEnableInputSource(parent)
            guard status == noErr else {
                lastFailure = "系统拒绝启用输入法组件（\(status)）。"
                return false
            }
        }
        // Do not select or trust a child until the parent actually became enabled.
        guard parentEnabled else { return true }
        return requestModeEnable()
    }

    static func requestModeEnable() -> Bool {
        guard parentEnabled, let source = modeSource else { return false }
        let status = TISEnableInputSource(source)
        if status != noErr { lastFailure = "系统拒绝启用语音输入模式（\(status)）。" }
        return status == noErr
    }

    static func selectEnabledMode() -> Bool {
        guard isEnabled, let source = modeSource else {
            lastFailure = "输入法尚未启用，不能切换。请在系统输入法设置中完成添加或允许。"
            return false
        }
        let status = TISSelectInputSource(source)
        // Doubao shortcut_direct: TIS accept is enough; selection is observed asynchronously.
        if status != noErr {
            lastFailure = "输入法已启用，但切换未完成（\(status)）。"
            return false
        }
        return true
    }

    // Kept for CLI diagnostics. GUI installation uses the asynchronous coordinator.
    static func enableAndSelect() -> Bool {
        guard requestEnable() else { return false }
        return selectEnabledMode()
    }

    static func ours(includeDisabled: Bool) -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleID]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, includeDisabled) else { return [] }
        return list.takeRetainedValue() as! [TISInputSource]
    }
    static var parentSource: TISInputSource? {
        ours(includeDisabled: true).first { string($0, kTISPropertyInputSourceID) == bundleID }
    }
    static var modeSource: TISInputSource? {
        ours(includeDisabled: true).first {
            string($0, kTISPropertyInputSourceID) == modeID && bool($0, kTISPropertyInputSourceIsSelectCapable)
        }
    }
    static var selectableSources: [TISInputSource] { modeSource.map { [$0] } ?? [] }
    static var parentEnabled: Bool { parentSource.map { bool($0, kTISPropertyInputSourceIsEnabled) } ?? false }
    static var isEnabled: Bool {
        guard parentEnabled, let mode = modeSource else { return false }
        return bool(mode, kTISPropertyInputSourceIsEnabled)
    }
    static var currentID: String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(current, kTISPropertyInputSourceID)
    }
    static var isSelected: Bool { currentID == modeID }
    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
    static func openSystemInputSourceSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources")!)
    }
}
