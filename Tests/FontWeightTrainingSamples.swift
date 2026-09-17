import AppKit
import CoreText

@main struct FontWeightTrainingSamples {
    static func main() throws {
        let root=URL(fileURLWithPath:"build/font-weight/native-training")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var seed:UInt64=391
        func next(_ n:Int)->Int { seed=seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed>>32)%UInt64(n)) }
        let families=["Arial","Times New Roman","Courier New","Tahoma","Trebuchet MS","Helvetica","PingFang SC"]
        let held=["Georgia","Verdana","Avenir Next"]
        let training=["The quick brown fox jumps over the lazy dog.","Learning and research require careful experiments.",
            "Please review these changes before the next release.","A practical guide to building reliable software.",
            "Read the article and check the original source.","Support independent projects and their contributors.",
            "Small details matter when designing a useful interface.","1234567890 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz"]
        let validation=["Fresh evidence should change our assumptions.","42 readers saved this message yesterday.","Download the report and continue your investigation."]
        let chinese=["这是一段用于测试文字粗细的普通中文内容。","软件开发需要认真验证，不能仅凭猜测作出结论。"]
        var manifest:[[String:Any]]=[]
        for index in 0..<7600 {
            let split=index<6000 ? "train" : index<6800 ? "validation" : "holdout"
            let names=split=="holdout" ? held : families
            let family=names[next(names.count)], bold=next(2)==1, dark=next(2)==1
            let pointSize=CGFloat(12+next(37))
            let candidates=family=="PingFang SC" ? chinese : split=="train" ? training : validation
            let text=candidates[next(candidates.count)]
            let initial=NSFont(name:family,size:pointSize)!
            let font=NSFontManager.shared.convert(initial,toHaveTrait:bold ? .boldFontMask : .unboldFontMask)
            // Verify requested labels from the actual selected font, never silently
            // label an unavailable bold face as bold.
            let traitBold=font.fontDescriptor.symbolicTraits.contains(.bold)
            if family != "PingFang SC" && traitBold != bold { continue }
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.font:font,.foregroundColor:dark ? NSColor.white : NSColor.black]))
            let ink=CTLineGetImageBounds(line,nil)
            let w=Int(ceil(ink.width))+12,h=Int(ceil(ink.height))+12
            let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:w*4,bitsPerPixel:32)!
            let context=NSGraphicsContext(bitmapImageRep:rep)!.cgContext
            context.setFillColor(CGColor(gray:dark ? 0.12:1,alpha:1));context.fill(CGRect(x:0,y:0,width:w,height:h))
            context.textPosition=CGPoint(x:6-ink.minX,y:6-ink.minY);context.textMatrix = .identity;CTLineDraw(line,context)
            let filename="\(index).png"
            try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(filename))
            manifest.append(["file":filename,"bold":bold ? 1:0,"family":family,"font":font.fontName,"size":pointSize,"dark":dark,"split":split])
        }
        try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:root.appendingPathComponent("manifest.json"))
        print("Generated \(manifest.count) native samples; user screenshots excluded")
    }
}
