import AppKit
import CoreML

@main struct ScreenFontWeightIntegrationTests {
    static func main() async throws {
        let args=CommandLine.arguments
        let image=NSImage(contentsOfFile:args[1])!
        let pixels=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let lines=try String(contentsOfFile:args[2],encoding:.utf8).split(separator:"\n").map { value -> ScreenOCRLine in
            let pair=value.split(separator:"\t",maxSplits:1)
            let coords=pair[0].trimmingCharacters(in:CharacterSet(charactersIn:"()"))
                .split(separator:",").map { Double($0.trimmingCharacters(in:.whitespaces))! }
            return ScreenOCRLine(text:String(pair[1]),visionBox:CGRect(x:coords[0],y:coords[1],width:coords[2],height:coords[3]))
        }
        struct Reference: Decodable {
            struct Row: Decodable {let text:String;let bold_probability:Double}
            let rows:[Row]
        }
        let reference=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
        let compiled: URL
        if args.count > 4 { compiled = URL(fileURLWithPath: args[4]) }
        else { compiled = try await MLModel.compileModel(at:URL(fileURLWithPath:"Sources/Resources/FontWeight.mlpackage")) }
        let service=ScreenFontWeightService(modelURL:compiled)
        let start=Date()
        let result=try await service.annotate(lines,pixels:pixels)
        let coldMS=Date().timeIntervalSince(start)*1000
        let warmStart=Date()
        let warm=try await service.annotate(lines,pixels:pixels)
        let warmMS=Date().timeIntervalSince(warmStart)*1000
        precondition(result == warm, "Cached model produces stable predictions")
        func decision(_ score:Double)->Int { score>=0.9 ? 1 : score<=0.1 ? 0 : -1 }
        var mismatches=0, maxDifference=0.0
        for (index,line) in result.enumerated() {
            precondition(line.text == reference.rows[index].text)
            guard let score=line.boldScore else { fatalError("Bundled model failed to predict") }
            let expected=reference.rows[index].bold_probability
            maxDifference=max(maxDifference,abs(expected-score))
            if decision(score) != decision(expected) {mismatches+=1; print("MISMATCH \(line.text): \(expected) -> \(score)")}
        }
        let missing=ScreenFontWeightService(modelURL:nil)
        let fallback=try await missing.annotate(lines,pixels:pixels)
        precondition(fallback==lines,"Missing model preserves original styles")
        let paragraphs=ScreenTranslate.groupParagraphs(from:result,canvasSize:image.size)
        var translated=paragraphs
        for i in translated.indices {translated[i].translation=translated[i].original}
        let layout=ScreenTranslate.layoutPlates(translated,canvasSize:image.size)
        for (i,item) in layout.enumerated() {
            let scores=translated[i].sourceLines.compactMap(\.boldScore).sorted()
            if let middle=scores.isEmpty ? nil : scores[scores.count/2] {
                if middle<=0.1 {precondition(!item.isHeading,"Confident regular source overrides heading weight")}
                if middle>=0.9 {precondition(item.isHeading,"Confident bold source is rendered bold")}
            }
        }
        print("Native preprocessing + Core ML: \(lines.count) lines; cold \(coldMS) ms, warm \(warmMS) ms; decision mismatches \(mismatches); max score difference \(maxDifference)")
        precondition(mismatches==0,"Native normalization must retain offline decisions on supplied fixtures")
    }
}
