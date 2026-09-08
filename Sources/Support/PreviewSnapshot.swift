import SwiftUI
import AppKit

#if DEBUG
@MainActor
enum PreviewSnapshot {
    static func takeSnapshot(model: AppModel, path: String) {
        let view = SettingsView()
            .environment(model)
            .frame(width: 820, height: 600)
        
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        if let nsImage = renderer.nsImage,
           let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
            print("Settings snapshot successfully written to \(path)")
        }
    }

    static func takeWaveformSnapshot(path: String) {
        let overlayModel = OverlayModel()
        overlayModel.phase = .listening
        overlayModel.levels = (0..<40).map { i in
            let s = sin(Double(i) * 0.28)
            return Float(abs(s) * 0.85 + 0.1)
        }
        let view = OverlayView(model: overlayModel)
            .padding(24)
            .background(Color.black.opacity(0.15))
        
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        if let nsImage = renderer.nsImage,
           let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
            print("Waveform snapshot successfully written to \(path)")
        }
    }
}
#endif
