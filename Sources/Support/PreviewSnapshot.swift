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

    private static func write<V: View>(_ view: V, to path: String, label: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        if let nsImage = renderer.nsImage,
           let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
            print("\(label) snapshot successfully written to \(path)")
        }
    }
}
#endif
