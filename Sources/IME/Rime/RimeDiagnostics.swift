import Foundation
import Carbon.HIToolbox

/// Runs against the actual app bundle without registering IMK, switching the
/// user's input source, touching their Rime DB or requesting any permissions.
enum RimeDiagnostics {
    static func run() -> Int32 {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("saylane-rime-smoke-\(UUID().uuidString)")
        defer {
            SLRimeFinalize()
            try? FileManager.default.removeItem(at: user)
        }
        do {
            guard let resource = Bundle.main.resourceURL?.appendingPathComponent("Rime") else {
                throw RimeRuntime.SetupError.missingData("Rime")
            }
            let start = ProcessInfo.processInfo.systemUptime
            let runtime = try RimeRuntime(sharedData: resource, userData: user)
            let session = try RimePinyinSession(runtime: runtime)
            print("librime \(runtime.version); bundle resources: \(resource.path)")
            for (input, expected) in [("nihao", "你好"), ("woxiangqubeijing", "我想去北京")] {
                for ch in input {
                    _ = session.handle(PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: String(ch),
                                                      letter: ch, flags: [], isRepeat: false), shiftToggleEnabled: true)
                }
                guard session.candidates.first?.word == expected else {
                    fputs("FAIL: first candidate for \(input)\n", stderr)
                    return EXIT_FAILURE
                }
                session.selectCandidate(at: 0)
                guard session.takeCommit() == expected && !session.isComposing else { return EXIT_FAILURE }
                print("PASS: \(input) -> \(expected)")
            }
            for ch in "nihao" {
                _ = session.handle(PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: String(ch),
                                                  letter: ch, flags: [], isRepeat: false), shiftToggleEnabled: true)
            }
            session.setEnglishMode(true)
            guard session.takeCommit() == "nihao" && !session.isComposing else { return EXIT_FAILURE }
            print(String(format: "PASS: bundled Rime and raw Latin switch; setup + smoke %.0f ms",
                         (ProcessInfo.processInfo.systemUptime - start) * 1000))
            return EXIT_SUCCESS
        } catch {
            fputs("FAIL: bundled Rime: \(error.localizedDescription)\n", stderr)
            return EXIT_FAILURE
        }
    }
}
