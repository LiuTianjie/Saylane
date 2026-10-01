import SwiftUI
import AppKit

#if DEBUG
@MainActor
enum PreviewSnapshot {
    static func takeSnapshot(model: AppModel, path: String) {
        write(SettingsView().environment(model).frame(width: 880, height: 680), to: path, label: "Settings")
    }

    static func takeSetupSnapshot(model: AppModel, path: String) {
        model.isShowingSetup = true
        model.settingsTab = 0
        write(SettingsView().environment(model).frame(width: 880, height: 680), to: path, label: "Setup")
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
