import AppKit
import Carbon
import Foundation

/// The main program manages the input method's input source: file placement,
/// TIS discovery, enablement, and selection are distinct states. In particular,
/// a mode's default-enabled flag is not proof its parent is enabled.
enum InputSourceInstall {
    /// Last failure text for the UI. TIS calls are made from the main thread only.
    nonisolated(unsafe) static var lastFailure: String?
    static var bundleID: String { Bridge.imeBundleID }
    static var modeID: String { bundleID + ".voice" }
    /// The input method bundle the installer puts in place.
    static var bundleURL: URL { URL(fileURLWithPath: Bridge.imeBundlePath, isDirectory: true) }
    static var isInstalledLocation: Bool {
        guard let bundle = Bundle(url: bundleURL) else { return false }
        return bundle.bundleIdentifier == bundleID
    }
    @discardableResult
    static func registerBundle() -> OSStatus {
        lastFailure = nil
        guard isInstalledLocation else {
            lastFailure = String(localized: "没有找到已安装的输入法组件，请先用安装包安装。")
            return OSStatus(paramErr)
        }
        let status = TISRegisterInputSource(bundleURL as CFURL)
        NSLog("Saylane: register status=%d path=%@", status, bundleURL.path)
        if status != noErr { lastFailure = String(localized: "系统输入法注册失败（错误码 \(status)）。") }
        return status
    }

    /// Issue enable requests from the running GUI app, not a short-lived installer process.
    /// The caller must allow time for system approval and re-read fresh TIS objects.
    static func requestEnable() -> Bool {
        guard registerBundle() == noErr else { return false }
        guard let parent = parentSource else {
            lastFailure = String(localized: "文件已安装，但系统尚未发现输入法组件。不能开始语音输入。")
            return false
        }
        if !bool(parent, kTISPropertyInputSourceIsEnabled) {
            let status = TISEnableInputSource(parent)
            guard status == noErr else {
                lastFailure = String(localized: "系统拒绝启用输入法组件（\(status)）。")
                return false
            }
        }
        // Parent and child state is observed asynchronously.  The GUI poller
        // enables the mode only after fresh TIS objects show the parent ready.
        return true
    }

    static func requestModeEnable() -> Bool {
        guard parentEnabled, let source = modeSource else { return false }
        let status = TISEnableInputSource(source)
        if status != noErr { lastFailure = String(localized: "系统拒绝启用语音输入模式（\(status)）。") }
        return status == noErr
    }

    static func selectEnabledMode() -> Bool {
        guard isEnabled, let source = modeSource else {
            lastFailure = String(localized: "输入法尚未启用，不能切换。请在系统输入法设置中完成添加或允许。")
            return false
        }
        let status = TISSelectInputSource(source)
        // TIS accept is enough; selection is observed asynchronously.
        if status != noErr {
            lastFailure = String(localized: "输入法已启用，但切换未完成（\(status)）。")
            return false
        }
        return true
    }

    // Kept for CLI diagnostics. GUI installation uses the asynchronous coordinator.
    static func enableAndSelect() -> Bool {
        guard requestEnable() else { return false }
        for _ in 0..<40 where !isEnabled {
            if parentEnabled { _ = requestModeEnable() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return selectEnabledMode()
    }

    /// Explicit uninstall path. Move away from this source before disabling its
    /// mode and parent so System Settings does not retain a selected ghost entry.
    static func disableForUninstall() -> Bool {
        lastFailure = nil
        var ok = true
        if isSelected, !selectASCIILayout() {
            lastFailure = String(localized: "卸载前无法切换到系统键盘布局。")
            ok = false
        } else if isSelected {
            for _ in 0..<20 where isSelected {
                RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            }
            if isSelected { lastFailure = String(localized: "卸载前的输入源切换未完成。"); ok = false }
        }
        if let mode = modeSource, bool(mode, kTISPropertyInputSourceIsEnabled) {
            let status = TISDisableInputSource(mode)
            if status != noErr { lastFailure = String(localized: "系统拒绝停用输入模式（\(status)）。"); ok = false }
        }
        if let parent = parentSource, bool(parent, kTISPropertyInputSourceIsEnabled) {
            let status = TISDisableInputSource(parent)
            if status != noErr { lastFailure = String(localized: "系统拒绝停用输入法组件（\(status)）。"); ok = false }
        }
        return ok
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

    static var asciiLayoutSource: TISInputSource? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              bool(source, kTISPropertyInputSourceIsEnabled),
              bool(source, kTISPropertyInputSourceIsSelectCapable) else { return nil }
        return source
    }
    static var asciiLayoutID: String? {
        asciiLayoutSource.flatMap { string($0, kTISPropertyInputSourceID) }
    }

    /// Reconnecting a stale IMK receiver needs an actual source transition.
    /// Use an already enabled system layout; never enable another input method.
    static func selectASCIILayout() -> Bool {
        guard let source = asciiLayoutSource else { return false }
        return TISSelectInputSource(source) == noErr
    }

    /// Select any enabled keyboard input source by ID (used to go back to the
    /// user's own input method after a global wake).
    @discardableResult
    static func select(inputSourceID: String) -> Bool {
        if inputSourceID == modeID { return selectEnabledMode() }
        let filter = [kTISPropertyInputSourceID as String: inputSourceID]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first(where: { bool($0, kTISPropertyInputSourceIsSelectCapable) }) else { return false }
        return TISSelectInputSource(source) == noErr
    }
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
