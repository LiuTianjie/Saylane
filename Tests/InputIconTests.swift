import AppKit
import Foundation

@main struct InputIconTests {
    static func main() throws {
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Sources/Info.plist")), format: nil) as! [String: Any]
        let modes = (info["ComponentInputModeDict"] as! [String: Any])["tsInputModeListKey"] as! [String: [String: Any]]
        let mode = modes["com.rtranslate.inputmethod.rtranslate.voice"]!
        for language in ["en", "zh-Hans"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Sources/Resources/\(language).lproj/InfoPlist.strings"))
            let strings = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            precondition(strings["CFBundleName"] == "RTranslate" && strings["CFBundleDisplayName"] == "RTranslate")
        }
        // Doubao IME uses menu_icon.pdf loaded by TIS file URL, not NSImage(named:).
        let icon = "menu_icon.pdf"
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
        precondition(opaque > 400 && opaque < 900)
        precondition(white == 0 && colored == 0 && black > 50)
        print("PASS: menu icon is Doubao-style menu_icon.pdf without Gray ICC")
    }
}
