import AppKit
import Foundation

// Doubao IME ships Contents/Resources/menu_icon.pdf (not *Template*).
// TextInputMenu loads that file by URL. A Quartz Generic-Gray ICC PDF stays
// black; Doubao's file is a 16pt filled glyph with plain 0 g / 0 0 0 scn.

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/Resources/menu_icon.pdf"

func circle(cx: Double, cy: Double, r: Double) -> String {
    let k = 0.5522847498307936 * r
    return """
        \(cx) \(cy + r) m
        \(cx + k) \(cy + r) \(cx + r) \(cy + k) \(cx + r) \(cy) c
        \(cx + r) \(cy - k) \(cx + k) \(cy - r) \(cx) \(cy - r) c
        \(cx - k) \(cy - r) \(cx - r) \(cy - k) \(cx - r) \(cy) c
        \(cx - r) \(cy + k) \(cx - k) \(cy + r) \(cx) \(cy + r) c
        h
        """
}

func capsule(cx: Double, cy: Double, width: Double, height: Double) -> String {
    let r = width / 2
    let x0 = cx - r
    let x1 = cx + r
    let y0 = cy - height / 2 + r
    let y1 = cy + height / 2 - r
    let k = 0.5522847498307936 * r
    return """
        \(x0) \(y1) m
        \(x0) \(y1 + k) \(cx - k) \(y1 + r) \(cx) \(y1 + r) c
        \(cx + k) \(y1 + r) \(x1) \(y1 + k) \(x1) \(y1) c
        \(x1) \(y0) l
        \(x1) \(y0 - k) \(cx + k) \(y0 - r) \(cx) \(y0 - r) c
        \(cx - k) \(y0 - r) \(x0) \(y0 - k) \(x0) \(y0) c
        h
        """
}

let operators = """
    0 g
    \(circle(cx: 8, cy: 8, r: 8))
    \(capsule(cx: 3.34, cy: 8, width: 1.47, height: 2.45))
    \(capsule(cx: 5.79, cy: 8, width: 1.47, height: 3.93))
    \(capsule(cx: 8.25, cy: 8, width: 1.47, height: 6.87))
    \(capsule(cx: 10.70, cy: 8, width: 1.47, height: 3.93))
    \(capsule(cx: 13.16, cy: 8, width: 1.47, height: 2.45))
    f*

    """
let stream = Data(operators.utf8)

func add(_ pdf: inout Data, _ string: String) {
    pdf.append(Data(string.utf8))
}

var pdf = Data("%PDF-1.4\n".utf8)
var xref: [Int] = [0]
func addObject(_ body: String) {
    xref.append(pdf.count)
    add(&pdf, body)
}

addObject("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
addObject("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
addObject("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 16 16] /Contents 4 0 R /Resources << /ProcSet [/PDF] >> >>\nendobj\n")
xref.append(pdf.count)
add(&pdf, "4 0 obj\n<< /Length \(stream.count) >>\nstream\n")
pdf.append(stream)
add(&pdf, "endstream\nendobj\n")
let startxref = pdf.count
add(&pdf, "xref\n0 5\n0000000000 65535 f \n")
for offset in xref.dropFirst() {
    add(&pdf, String(format: "%010d 00000 n \n", offset))
}
add(&pdf, "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(startxref)\n%%EOF\n")
try pdf.write(to: URL(fileURLWithPath: output), options: .atomic)

let text = String(decoding: pdf, as: UTF8.self)
precondition(!text.contains("Generic Gray Profile"))
precondition(!text.contains("ICCBased"))
precondition(text.contains("0 g"))
guard let image = NSImage(contentsOfFile: output), image.size == NSSize(width: 16, height: 16) else {
    fatalError("Wrong logical icon size")
}
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let bitmap = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Bitmap unavailable")
}
var rect = CGRect(x: 0, y: 0, width: 32, height: 32)
bitmap.draw(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!, in: rect)
let pixels = bitmap.data!.assumingMemoryBound(to: UInt8.self)
precondition(pixels[3] == 0 && pixels[(32 * 32 - 1) * 4 + 3] == 0)
let opaqueCount = (0..<1024).filter { pixels[$0 * 4 + 3] > 200 }.count
precondition(opaqueCount > 400 && opaqueCount < 900, "Filled disk with waveform holes, got \(opaqueCount)")
let png = NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
print("PASS: Doubao-style 16pt filled PDF, no ICC, \(opaqueCount)/1024 opaque pixels")
