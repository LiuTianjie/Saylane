import AppKit
import Foundation

// The input-menu icon: a speech bubble with a text cursor cut out of it —
// what is said lands at the caret. Saylane's own mark.
//
// The input menu loads this file by URL and tints it as a template, so it is a
// hand-written 16 pt PDF: one path filled with plain DeviceGray black and the
// even-odd rule, no colour profile. (A PDF with an ICC profile stays black on a
// dark menu bar.) Sub-paths must not overlap each other: under the even-odd
// rule an overlap would turn back into a fill.

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/Resources/InputMenuIcon.pdf"

func roundedRect(x: Double, y: Double, width: Double, height: Double, radius r: Double) -> String {
    let k = 0.5522847498307936 * r
    let x1 = x + width, y1 = y + height
    return """
        \(x + r) \(y) m
        \(x1 - r) \(y) l
        \(x1 - r + k) \(y) \(x1) \(y + r - k) \(x1) \(y + r) c
        \(x1) \(y1 - r) l
        \(x1) \(y1 - r + k) \(x1 - r + k) \(y1) \(x1 - r) \(y1) c
        \(x + r) \(y1) l
        \(x + r - k) \(y1) \(x) \(y1 - r + k) \(x) \(y1 - r) c
        \(x) \(y + r) l
        \(x) \(y + r - k) \(x + r - k) \(y) \(x + r) \(y) c
        h
        """
}

func polygon(_ points: [(Double, Double)]) -> String {
    var lines = ["\(points[0].0) \(points[0].1) m"]
    for point in points.dropFirst() { lines.append("\(point.0) \(point.1) l") }
    lines.append("h")
    return lines.joined(separator: "\n")
}

/// A text cursor as one outline: a stem with a serif at each end.
func cursor(cx: Double, bottom: Double, top: Double, stem: Double, serif: Double, thickness t: Double) -> String {
    let a = stem / 2, b = serif / 2
    return polygon([
        (cx - b, top), (cx + b, top), (cx + b, top - t), (cx + a, top - t),
        (cx + a, bottom + t), (cx + b, bottom + t), (cx + b, bottom), (cx - b, bottom),
        (cx - b, bottom + t), (cx - a, bottom + t), (cx - a, top - t), (cx - b, top - t),
    ])
}

let bodyBottom = 4.25
let operators = """
    0 g
    \(roundedRect(x: 1, y: bodyBottom, width: 14, height: 10.75, radius: 3.5))
    \(polygon([(3.75, bodyBottom), (3.25, 1.5), (7.25, bodyBottom)]))
    \(cursor(cx: 8, bottom: 6.75, top: 12.5, stem: 1.5, serif: 4.25, thickness: 1.25))
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
func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 32 + x) * 4 + 3] }
// Corners are empty, the bubble is filled, and the cursor is a hole in it.
precondition(alpha(0, 0) == 0 && alpha(31, 31) == 0 && alpha(31, 0) == 0)
precondition(alpha(6, 12) > 200 && alpha(25, 12) > 200, "the bubble is filled on both sides of the cursor")
precondition(alpha(16, 12) == 0, "the cursor's stem is cut out")
let opaqueCount = (0..<1024).filter { pixels[$0 * 4 + 3] > 200 }.count
precondition(opaqueCount > 380 && opaqueCount < 620, "a bubble with a cursor cut out, got \(opaqueCount)")
print("PASS: 16 pt template PDF, no colour profile, \(opaqueCount)/1024 opaque pixels")
