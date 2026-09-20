import AppKit
import AVFoundation
import CoreGraphics
import Observation
import Speech

@MainActor @Observable
final class PermissionService {
    enum Status: Equatable { case granted, denied, notDetermined }
    var isRequestingMicrophone = false
    var isRequestingSpeech = false
    var microphone: Status = .notDetermined
    var speechRecognition: Status = .notDetermined
    var inputMonitoringGranted = false
    var screenCaptureGranted = false
    var allCriticalGranted: Bool { microphone == .granted }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechRecognition = .granted
        case .notDetermined: speechRecognition = .notDetermined
        default: speechRecognition = .denied
        }
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapture() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
        if !screenCaptureGranted {
            Self.openPrivacy("Privacy_ScreenCapture")
        }
    }

    func requestInputMonitoring() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        refresh()
        if !inputMonitoringGranted {
            Self.openPrivacy("Privacy_ListenEvent")
        }
    }

    func requestMicrophone() async {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        defer { isRequestingMicrophone = false }
        refresh()
        if microphone == .granted { return }
        if microphone == .denied {
            Self.openPrivacy("Privacy_Microphone")
        } else {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
            if microphone != .granted {
                Self.openPrivacy("Privacy_Microphone")
            }
        }
    }

    func requestSpeechRecognition() async {
        guard !isRequestingSpeech else { return }
        isRequestingSpeech = true
        defer { isRequestingSpeech = false }
        refresh()
        if speechRecognition == .granted { return }
        if speechRecognition == .denied {
            Self.openPrivacy("Privacy_SpeechRecognition")
            return
        }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        refresh()
        if status != .authorized {
            Self.openPrivacy("Privacy_SpeechRecognition")
        }
    }

    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
