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
                              speechRecognition: Self.status(service.speechRecognition),
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

    func openInputMethodSettings() {
        InputSourceInstall.openSystemInputSourceSettings()
        if InputSourceInstall.isInstalledLocation { enableInputSource() }
    }

    func requestSpeechRecognition() async {
        await service.requestSpeechRecognition()
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

    // MARK: - Enable the input source

    func enableInputSource() {
        guard !isActivatingInputSource else { return }
        isActivatingInputSource = true
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isActivatingInputSource = false; self.onChanged?() }
            guard InputSourceInstall.requestEnable() else {
                self.onNotice?(.actionable(InputSourceInstall.lastFailure ?? String(localized: "系统尚未发现输入法。"), .permissions))
                return
            }
            // Keep the GUI run loop alive for the native approval flow. Fresh handles
            // are queried on every poll; no preference writes or unrelated IME toggles.
            var requestedMode = false
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                self.onChanged?()
                if InputSourceInstall.isEnabled {
                    if !InputSourceInstall.selectEnabledMode() {
                        self.onNotice?(.actionable(InputSourceInstall.lastFailure ?? String(localized: "切换未完成。"), .permissions))
                    }
                    return
                }
                // Enabling the parent and publishing its child are asynchronous.
                // Re-read fresh objects and issue an idempotent child request;
                // never infer that it was requested merely because the parent
                // happened to flip state between two reads.
                if InputSourceInstall.parentEnabled, !requestedMode,
                   InputSourceInstall.requestModeEnable() {
                    requestedMode = true
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.onNotice?(.actionable(InputSourceInstall.lastFailure
                ?? String(localized: "文件已安装，但系统尚未启用 Saylane。请完成系统的允许或添加操作；若添加列表仍不可见，请保存工作后注销并重新登录。"), .permissions))
        }
    }
}
