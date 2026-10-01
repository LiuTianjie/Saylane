import AppKit
import Foundation
import Observation

/// Permission requests and the input-source enable flow. It reports outcomes as
/// notices and readiness events; it never opens the settings window itself.
@MainActor @Observable
final class PermissionsController {
    let service = PermissionService()
    private(set) var isActivatingInputSource = false
    private var activationTask: Task<Void, Never>?
    var onNotice: ((UserNotice) -> Void)?
    /// Something observable changed (permission, input source); the host re-reduces readiness.
    var onChanged: (() -> Void)?

    var permissions: Readiness.Permissions {
        Readiness.Permissions(microphone: Self.status(service.microphone),
                              inputMonitoring: service.inputMonitoringGranted,
                              screenCapture: service.screenCaptureGranted,
                              accessibility: AccessibilityInserter.isTrusted)
    }

    var inputSource: Readiness.InputSource {
        Readiness.InputSource(installedLocation: InputSourceInstall.isInstalledLocation,
                              installed: !InputSourceInstall.ours(includeDisabled: true).isEmpty,
                              enabled: InputSourceInstall.isEnabled,
                              selected: InputSourceInstall.isSelected)
    }

    func refresh() { service.refresh() }

    private static func status(_ value: PermissionService.Status) -> Readiness.PermissionStatus {
        switch value {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        }
    }

    // MARK: - Requests

    /// Make Saylane the current input method. It is already in the list.
    func selectInputSource() {
        // A test home looks at the input sources of this Mac and leaves them alone.
        guard !TestHome.isActive else { return }
        if InputSourceInstall.isEnabled, !InputSourceInstall.isSelected, !InputSourceInstall.selectEnabledMode() {
            onNotice?(.actionable(InputSourceInstall.lastFailure ?? String(localized: "切换未完成。"), .permissions))
        }
        onChanged?()
    }

    /// Returns whether the microphone is granted afterwards.
    @discardableResult
    func requestMicrophone() async -> Bool {
        await service.requestMicrophone()
        onChanged?()
        return service.microphone == .granted
    }

    func requestInputMonitoring() {
        service.requestInputMonitoring()
        onChanged?()
    }

    func requestAccessibility() {
        AccessibilityInserter.requestTrust()
        PermissionService.openPrivacy("Privacy_Accessibility")
        onChanged?()
    }

    /// Returns whether screen capture is granted afterwards.
    @discardableResult
    func requestScreenCapture() -> Bool {
        service.requestScreenCapture()
        onChanged?()
        return service.screenCaptureGranted
    }

    // MARK: - Add the input source

    /// How long the system gets to add the input source before the user is
    /// shown where to do it by hand.
    static let addInPlaceLimit: Duration = .seconds(8)

    /// Add Saylane to the input sources and, if asked, make it the current one
    /// — from here, the way other input methods install themselves. System
    /// Settings is opened only when the system does not go along.
    func addInputSource(select: Bool) {
        guard !isActivatingInputSource, !TestHome.isActive else { return }
        isActivatingInputSource = true
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isActivatingInputSource = false; self.onChanged?() }
            guard InputSourceInstall.requestEnable() else {
                self.onNotice?(.actionable(InputSourceInstall.lastFailure ?? String(localized: "系统尚未发现输入法。"), .permissions))
                return
            }
            // Enabling the component and publishing its mode are asynchronous:
            // fresh handles are read on every poll and the mode is requested
            // once, after the component shows up enabled.
            var requestedMode = false
            var openedSettings = false
            let start = ContinuousClock.now
            for _ in 0..<240 {
                guard !Task.isCancelled else { return }
                self.onChanged?()
                if InputSourceInstall.isEnabled {
                    if select, !InputSourceInstall.selectEnabledMode() {
                        self.onNotice?(.actionable(InputSourceInstall.lastFailure ?? String(localized: "切换未完成。"), .permissions))
                    }
                    return
                }
                if InputSourceInstall.parentEnabled, !requestedMode,
                   InputSourceInstall.requestModeEnable() {
                    requestedMode = true
                }
                if !openedSettings, ContinuousClock.now - start > Self.addInPlaceLimit {
                    // The system did not add it by itself: show where it is done by hand.
                    openedSettings = true
                    InputSourceInstall.openSystemInputSourceSettings()
                    self.onNotice?(.actionable(String(localized: "系统没有自动添加 Saylane。已打开系统设置：在输入法列表下点 +，选择「简体中文」里的 Saylane。"), .permissions))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.onNotice?(.actionable(InputSourceInstall.lastFailure
                ?? String(localized: "文件已安装，但系统尚未启用 Saylane。请完成系统的允许或添加操作；若添加列表仍不可见，请保存工作后注销并重新登录。"), .permissions))
        }
    }
}
