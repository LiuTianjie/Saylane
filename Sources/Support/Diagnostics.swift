import AVFoundation
import Carbon
import Foundation
import Speech

/// Opt-in command-line diagnostics. Never record audio or transcribed user text automatically.
@MainActor enum Diagnostics {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            if arguments.contains("--diagnose") {
                let locales = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
                let result: [String: Any] = [
                    "bundlePath": Bundle.main.bundlePath,
                    "bundleID": Bundle.main.bundleIdentifier ?? "",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    "inputSources": InputSourceInstall.ours(includeDisabled: true).map { source in
                        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
                        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                    },
                    "enabled": InputSourceInstall.isEnabled,
                    "selected": InputSourceInstall.isSelected,
                    "speechAvailable": SpeechTranscriber.isAvailable,
                    "installedSpeechLocales": locales,
                    "microphoneStatus": AVCaptureDevice.authorizationStatus(for: .audio).rawValue
                ]
                print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                return 0
            }
            if let index = arguments.firstIndex(of: "--recognize-file"), arguments.count > index + 1 {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[index + 1]))
                let locale = arguments.count > index + 2 ? arguments[index + 2] : "zh-CN"
                let engine = SpeechEngine()
                var partialCount = 0
                engine.onPartial = { _ in partialCount += 1 }
                try await engine.begin(locale: Locale(identifier: locale))
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else { throw SpeechEngineError.invalidFormat }
                    try file.read(into: buffer)
                    try engine.feed(buffer)
                    await Task.yield()
                }
                let result = try await engine.finish()
                print("partials=\(partialCount)\nfinal=\(result)")
                return result.isEmpty ? 1 : 0
            }
            if arguments.contains("--translation-check") {
                let engine = TranslationEngine()
                try await engine.prepareInstalled(source: Locale.Language(identifier: "zh-Hans"), target: Locale.Language(identifier: "en"))
                let translated = try await engine.translate("今天下午我们一起去公园散步。")
                print(translated)
                return translated.isEmpty ? 1 : 0
            }
            return 2
        } catch {
            fputs("Diagnostic failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
