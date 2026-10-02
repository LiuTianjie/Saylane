import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case notAuthorized
    case noDisplay
    case failed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return String(localized: "所见即译需要屏幕录制权限。")
        case .noDisplay: return String(localized: "找不到这块屏幕。")
        case .failed: return String(localized: "截取屏幕失败，请重试。")
        }
    }
}

enum ScreenCaptureService {
    /// The few facts about an `NSScreen` the capture needs, so the capture can run off the main actor.
    struct Display: Sendable {
        var frame: CGRect
        var displayID: CGDirectDisplayID
        var backingScaleFactor: CGFloat

        @MainActor init(_ screen: NSScreen) {
            frame = screen.frame
            displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            backingScaleFactor = screen.backingScaleFactor
        }
    }

    @MainActor static func capture(rectInScreen: CGRect, screen: NSScreen) async throws -> NSImage {
        try await capture(rectInScreen: rectInScreen, display: Display(screen))
    }

    static func capture(rectInScreen: CGRect, display screen: Display) async throws -> NSImage {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.notAuthorized }
        let source = ScreenTranslate.captureSourceRect(appKitRect: rectInScreen, screenFrame: screen.frame)
        guard source.width >= ScreenTranslate.minimumSelection, source.height >= ScreenTranslate.minimumSelection else {
            throw ScreenCaptureError.failed
        }
        let displayID = screen.displayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(1, Int((source.width * screen.backingScaleFactor).rounded()))
        config.height = max(1, Int((source.height * screen.backingScaleFactor).rounded()))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: image, size: source.size)
    }
}
