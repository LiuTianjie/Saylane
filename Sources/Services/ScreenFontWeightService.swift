import AppKit
import CoreML

/// Serialized, off-main inference. The small bundled model is loaded once;
/// missing/failed predictions preserve the existing rendering behavior.
actor ScreenFontWeightService {
    static let shared = ScreenFontWeightService()
    static let preferenceKey = "screenFontWeightExperiment"
    private var model: MLModel?
    private var attemptedLoad = false
    private let modelURL: URL?

    init(modelURL: URL? = Bundle.main.url(forResource: "FontWeight", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    static func annotate(_ lines: [ScreenOCRLine], image: NSImage) async throws -> [ScreenOCRLine] {
        guard UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true,
            let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return lines }
        return try await shared.annotate(lines, pixels: pixels)
    }

    func annotate(_ lines: [ScreenOCRLine], pixels: CGImage) throws -> [ScreenOCRLine] {
        try Task.checkCancellation()
        if !attemptedLoad {
            attemptedLoad = true
            if let modelURL {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuOnly
                model = try? MLModel(contentsOf: modelURL, configuration: config)
            }
        }
        guard let model else { return lines }
        var result = lines
        for i in lines.indices {
            try Task.checkCancellation()
            do {
                let patches = Self.patches(image: pixels, box: lines[i].visionBox)
                var scores: [Double] = []
                for patch in patches {
                    try Task.checkCancellation()
                    let input = try MLMultiArray(shape: [1, 1, 32, 128], dataType: .float32)
                    patch.withUnsafeBytes { bytes in
                        input.dataPointer.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                    }
                    let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ink": input]))
                    if let logits = prediction.featureValue(for: "logits")?.multiArrayValue, logits.count == 2 {
                        let score = 1 / (1 + exp(logits[0].doubleValue - logits[1].doubleValue))
                        if score.isFinite { scores.append(score) }
                    }
                }
                if !scores.isEmpty { result[i].boldScore = scores.sorted()[scores.count / 2] }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Keep this line's existing style on model failure. */ }
        }
        return result
    }

    /// Same polarity, percentile and aspect-preserving resize as the Python
    /// experiment. Inputs and outputs are compared by the native parity test.
    static func patches(image: CGImage, box: CGRect) -> [[Float]] {
        let x = max(0, Int(box.minX * CGFloat(image.width)) - 2)
        let y = max(0, Int((1 - box.maxY) * CGFloat(image.height)) - 2)
        let right = min(image.width, Int(box.maxX * CGFloat(image.width)) + 3)
        let bottom = min(image.height, Int((1 - box.minY) * CGFloat(image.height)) + 3)
        guard right > x, bottom > y,
            let crop = image.cropping(to: CGRect(x: x, y: y, width: right - x, height: bottom - y)) else { return [] }
        let w = crop.width, h = crop.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }
        var gray = [Float](repeating: 0, count: w * h)
        for i in gray.indices {
            gray[i] = Float((Int(rgba[i*4])*299 + Int(rgba[i*4+1])*587 + Int(rgba[i*4+2])*114 + 500) / 1000)
        }
        var border: [Float] = []
        for xx in 0..<w { border.append(gray[xx]); border.append(gray[(h-1)*w+xx]) }
        for yy in 0..<h { border.append(gray[yy*w]); border.append(gray[yy*w+w-1]) }
        border.sort()
        let paper = (border[(border.count-1)/2]+border[border.count/2])/2
        let distance = gray.map { abs($0-paper) }
        let sorted = distance.sorted()
        let rank = Double(sorted.count-1)*0.98
        let lo = Int(rank), hi = min(sorted.count-1,lo+1)
        let contrast = max(1, sorted[lo] + (sorted[hi]-sorted[lo])*Float(rank-Double(lo)))
        let ink = distance.map { UInt8(min(255, max(0, $0/contrast*255))) }
        var left=w, top=h, r=0, b=0, inkCount=0
        for yy in 0..<h { for xx in 0..<w where ink[yy*w+xx] > 50 {
            left=min(left,xx);top=min(top,yy);r=max(r,xx+1);b=max(b,yy+1);inkCount += 1
        } }
        guard inkCount >= 8, r>left,b>top else { return [] }
        let sw=r-left, sh=b-top
        let dw=max(1,Int((Double(sw)*24/Double(sh)).rounded(.toNearestOrEven)))
        // Pillow bilinear uses a wider filter during downsampling, rounding
        // intermediate horizontal results to 8 bits before the vertical pass.
        func weights(_ from: Int, _ to: Int, _ index: Int) -> [(Int, Double)] {
            let scale=Double(from)/Double(to), support=max(1,scale)
            let center=(Double(index)+0.5)*scale
            let first=max(0,Int(floor(center-support+0.5)))
            let end=min(from,Int(floor(center+support+0.5)))
            var values:[(Int,Double)]=[];var sum=0.0
            for j in first..<max(first,end) {
                let weight=max(0,1-abs((Double(j)+0.5-center)/support))
                values.append((j,weight));sum += weight
            }
            return values.map { ($0.0,$0.1/max(sum,0.0001)) }
        }
        var output:[[Float]]=[]
        for fraction in [0.0,0.5,1.0] {
            let start=Int((Double(max(0,dw-128))*fraction).rounded(.toNearestOrEven))
            let visible=min(128,dw-start)
            var horizontal=[Float](repeating:0,count:visible*sh)
            for xx in 0..<visible {
                let taps=weights(sw,dw,start+xx)
                for yy in 0..<sh {
                    let value=taps.reduce(0.0) { $0+Double(ink[(yy+top)*w+left+$1.0])*$1.1 }
                    horizontal[yy*visible+xx]=Float(value.rounded())
                }
            }
            var patch=[Float](repeating:0,count:32*128)
            for yy in 0..<24 {
                let taps=weights(sh,24,yy)
                for xx in 0..<visible {
                    let value=taps.reduce(0.0) { $0+Double(horizontal[$1.0*visible+xx])*$1.1 }
                    patch[(yy+4)*128+xx]=Float(value.rounded()/255)
                }
            }
            output.append(patch)
        }
        return output
    }
}
