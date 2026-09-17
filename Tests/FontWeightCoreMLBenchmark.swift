import Foundation
import CoreML

@main struct FontWeightCoreMLBenchmark {
    static func main() throws {
        let args=CommandLine.arguments
        let compileStart=Date()
        let url=try MLModel.compileModel(at:URL(fileURLWithPath:args[1]))
        let compileMS=Date().timeIntervalSince(compileStart)*1000
        let config=MLModelConfiguration();config.computeUnits = .cpuOnly
        let loadStart=Date()
        let model=try MLModel(contentsOf:url,configuration:config)
        let loadMS=Date().timeIntervalSince(loadStart)*1000
        let bytes=try Data(contentsOf:URL(fileURLWithPath:args[2]))
        let count=bytes.count/(32*128*4)
        var inputs:[MLFeatureProvider]=[]
        for index in 0..<count {
            let array=try MLMultiArray(shape:[1,1,32,128],dataType:.float32)
            bytes.withUnsafeBytes { raw in
                array.dataPointer.copyMemory(from:raw.baseAddress!+index*32*128*4,byteCount:32*128*4)
            }
            inputs.append(try MLDictionaryFeatureProvider(dictionary:["ink":array]))
        }
        var times:[Double]=[];var outputs:[[Double]]=[]
        for round in 0..<12 {
            let start=Date();var values:[[Double]]=[]
            for input in inputs {
                let result=try model.prediction(from:input).featureValue(for:"logits")!.multiArrayValue!
                values.append([result[0].doubleValue,result[1].doubleValue])
            }
            times.append(Date().timeIntervalSince(start)*1000)
            if round==0 {outputs=values}
        }
        let warm=Array(times.dropFirst()).sorted()
        let report:[String:Any] = ["compile_ms":compileMS,"load_ms":loadMS,"patch_count":count,
            "first_run_ms":times[0],"warm_median_ms":warm[warm.count/2],"warm_max_ms":warm.last!,"logits":outputs]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:args[3]))
        print("Core ML CPU: \(count) patches; load \(loadMS) ms, first \(times[0]) ms, warm median \(warm[warm.count/2]) ms")
    }
}
