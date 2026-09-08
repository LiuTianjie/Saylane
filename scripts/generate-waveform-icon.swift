import AppKit
import SwiftUI

// A standalone 16pt waveform: no speech-bubble outline or rectangular backing.
// Production template silhouette; system UI supplies the foreground tint.
let cs = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
    bytesPerRow: 128, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.scaleBy(x: 2, y: 2)
context.setStrokeColor(CGColor(gray: 0, alpha: 1))
context.setLineWidth(1.7)
context.setLineCap(.round)
for (x, height): (CGFloat, CGFloat) in [(2.8, 3), (5.4, 7), (8, 12), (10.6, 8.5), (13.2, 4)] {
    context.move(to: CGPoint(x: x, y: 8 - height / 2))
    context.addLine(to: CGPoint(x: x, y: 8 + height / 2))
    context.strokePath()
}
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
rep.size = NSSize(width: 16, height: 16)
let path = "Sources/Resources/VoiceWaveformTemplate-v6.tiff"
try rep.representation(using: .tiff, properties: [:])!.write(to: URL(fileURLWithPath: path))
let image = NSImage(contentsOfFile: path)!
@MainActor func preview() throws {
    let view = VStack(spacing: 0) {
        HStack(spacing: 20) {
            Image(nsImage: image).renderingMode(.template).frame(width: 16, height: 16)
            Text("RTranslate").font(.system(size: 14, weight: .medium))
            Spacer()
            Text("16 pt").font(.system(size: 11)).opacity(0.5)
        }.foregroundStyle(.black).padding(22).background(Color(white: 0.96))
        HStack(spacing: 20) {
            Image(nsImage: image).renderingMode(.template).frame(width: 16, height: 16)
            Text("RTranslate").font(.system(size: 14, weight: .medium))
            Spacer()
            Text("16 pt").font(.system(size: 11)).opacity(0.5)
        }.foregroundStyle(.white).padding(22).background(Color(white: 0.12))
    }.frame(width: 320)
    let render = ImageRenderer(content: view); render.scale = 2
    let result = NSBitmapImageRep(data: render.nsImage!.tiffRepresentation!)!
    try result.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/diagnostics/waveform-candidate-preview.png"))
}
try MainActor.assumeIsolated { try preview() }
print("Generated production waveform template resource")
