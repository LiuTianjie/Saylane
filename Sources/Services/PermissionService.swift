import AppKit
import AVFoundation
import CoreGraphics
import Observation

@MainActor @Observable
final class PermissionService {
    enum Status: Equatable { case granted, denied, notDetermined }
    var isRequestingMicrophone = false
    var microphone: Status = .notDetermined
    var inputMonitoringGranted = false
    var allCriticalGranted: Bool { microphone == .granted }
    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }
    func requestInputMonitoring() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        refresh()
        if !inputMonitoringGranted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }
    func requestMicrophone() async {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        defer { isRequestingMicrophone = false }
        refresh()
        if microphone == .granted { return }
        if microphone == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        } else {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
    }
}
