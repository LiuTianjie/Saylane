import SwiftUI
import AppKit

#if DEBUG
@MainActor
enum PreviewSnapshot {
    /// The window is 680 pt tall; a taller snapshot shows a whole page at once.
    private static var height: CGFloat {
        ProcessInfo.processInfo.environment["SAYLANE_SNAPSHOT_HEIGHT"].flatMap(Double.init).map { CGFloat($0) } ?? 680
    }

    static func takeSnapshot(model: AppModel, path: String) {
        write(SettingsView().environment(model).frame(width: 880, height: height), to: path, label: "Settings")
    }

    static func takeSetupSnapshot(model: AppModel, path: String) {
        // "SAYLANE_SNAPSHOT_SETUP=2": the guide with its first two items on.
        if let count = ProcessInfo.processInfo.environment["SAYLANE_SNAPSHOT_SETUP"].flatMap(Int.init) {
            model.testChecklist = SetupChecklist(inputMethod: count >= 1, microphone: count >= 2,
                                                 accessibility: count >= 3, screenRecording: count >= 4)
        }
        model.isShowingSetup = true
        model.settingsTab = 0
        write(SettingsView().environment(model).frame(width: 880, height: height), to: path, label: "Setup")
    }

    static func takeWaveformSnapshot(path: String) {
        let overlayModel = OverlayModel()
        overlayModel.phase = .listening
        overlayModel.levels = (0..<40).map { i in
            let s = sin(Double(i) * 0.28)
            return Float(abs(s) * 0.85 + 0.1)
        }
        write(OverlayView(model: overlayModel).padding(24).background(Color.black.opacity(0.15)),
              to: path, label: "Waveform")
    }

    /// Rendered through a real hosting view in an off-screen window: scroll
    /// views and controls do not draw in `ImageRenderer`.
    private static func write<V: View>(_ view: V, to path: String, label: String) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("\(label) snapshot successfully written to \(path)")
        }
    }
}
#endif
