import AppKit
import Foundation

@main struct InputIconTests {
    static func main() throws {
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Sources/IME/Info.plist")), format: nil) as! [String: Any]
        let modes = (info["ComponentInputModeDict"] as! [String: Any])["tsInputModeListKey"] as! [String: [String: Any]]
        let mode = modes["com.rtranslate.inputmethod.rtranslate.voice"]!
        for language in ["en", "zh-Hans"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Sources/Resources/\(language).lproj/InfoPlist.strings"))
            let strings = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            precondition(strings["CFBundleName"] == "Saylane" && strings["CFBundleDisplayName"] == "Saylane")
        }
        // The input menu loads the file by URL and tints it as a template.
        let icon = "InputMenuIcon.pdf"
        precondition(info["tsInputMethodIconFileKey"] as? String == icon)
        precondition(mode["tsInputModeMenuIconFileKey"] as? String == icon)
        precondition(mode["tsInputModePaletteIconFileKey"] as? String == icon)
        precondition(mode["tsInputModeAlternateMenuIconFileKey"] == nil)
        let pdf = try Data(contentsOf: URL(fileURLWithPath: "Sources/Resources/" + icon))
        let payload = String(decoding: pdf, as: UTF8.self)
        precondition(!payload.contains("Generic Gray Profile"))
        precondition(!payload.contains("ICCBased"))
        let image = NSImage(contentsOfFile: "Sources/Resources/" + icon)!
        precondition(image.size == NSSize(width: 16, height: 16))
        let w = 32, h = 32
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        context.draw(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!, in: rect)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        precondition([0, 31, 992, 1023].allSatisfy { pixels[$0 * 4 + 3] == 0 })
        var opaque = 0, white = 0, black = 0, colored = 0
        for i in 0..<1024 {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2]), a = Int(pixels[i * 4 + 3])
            if a > 20 {
                opaque += 1
                if r > 220 && g > 220 && b > 220 { white += 1 }
                if r < 40 && g < 40 && b < 40 { black += 1 }
                if abs(r - g) > 20 || abs(g - b) > 20 { colored += 1 }
            }
        }
        precondition(opaque > 380 && opaque < 620, "\(opaque)")
        precondition(white == 0 && colored == 0 && black > 50)
        // Saylane's own mark: a speech bubble with a text cursor cut out of it.
        // (Until 0.4 this was a copy of another input method's disc with five bars.)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * w + x) * 4 + 3]) }
        precondition(alpha(6, 12) > 200 && alpha(25, 12) > 200 && alpha(16, 12) == 0, "a bubble with the cursor's stem cut out")
        precondition(alpha(16, 31) == 0 && alpha(16, 0) == 0 && alpha(0, 16) == 0, "not a disc: empty above, below and beside the bubble")
        precondition(!FileManager.default.fileExists(atPath: "Sources/Resources/menu_icon.pdf"))
        print("PASS: the input-menu icon is Saylane's own template mark, 16 pt, without a colour profile")
    }
}
