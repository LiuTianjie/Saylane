import AVFoundation
import Carbon
import Foundation
import Speech
import MLXASR
import Darwin

/// Opt-in command-line diagnostics. Never record audio or transcribed user text automatically.
@MainActor enum Diagnostics {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            if let index = arguments.firstIndex(of: "--qwen-worker") {
                guard arguments.count > index + 1,
                      let variant = SpeechModel(rawValue: arguments[index + 1]), variant.isQwen else { return 2 }
                return await runQwenWorker(variant)
            }
            if let index = arguments.firstIndex(of: "--asr-memory-check") {
                guard arguments.count > index + 1 else { return 2 }
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[index + 1]))
                let audio = QwenAudioBuffer()
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else { throw SpeechEngineError.invalidFormat }
                    try file.read(into: buffer)
                    try audio.append(buffer)
                }
                memoryReport("baseline")
                for cycle in 1...2 {
                    for variant in [SpeechModel.qwen4bit, .qwen6bit] {
                        var start = Date()
                        try await QwenRuntime.shared.prepare(variant)
                        print(await QwenRuntime.shared.diagnostics())
                        memoryReport("cycle=\(cycle) \(variant.rawValue) loaded seconds=\(Date().timeIntervalSince(start))")
                        start = Date()
                        _ = try await QwenRuntime.shared.transcribe(audio.samples, language: "Chinese", variant: variant)
                        print(await QwenRuntime.shared.diagnostics())
                        memoryReport("inference seconds=\(Date().timeIntervalSince(start))")
                        let workerInfo = await QwenRuntime.shared.diagnostics()
                        guard let first = workerInfo.split(separator: " ").first,
                              let pid = Int32(first.replacingOccurrences(of: "workerPID=", with: "")) else { return 1 }
                        start = Date()
                        await QwenRuntime.shared.unload()
                        guard kill(pid, 0) == -1, errno == ESRCH else {
                            fputs("Worker still alive after unload\n", stderr)
                            return 1
                        }
                        memoryReport("unloaded seconds=\(Date().timeIntervalSince(start))")

                    }
                }
                let interrupted = Task { try await QwenRuntime.shared.prepare(.qwen4bit) }
                try await Task.sleep(for: .milliseconds(100))
                await QwenRuntime.shared.unload()
                _ = await interrupted.result
                try await QwenRuntime.shared.prepare(.qwen6bit)
                await QwenRuntime.shared.unload()
                print("Interrupted loading released; next model recovered")
                try await QwenRuntime.shared.prepare(.qwen4bit)
                let info = await QwenRuntime.shared.diagnostics()
                guard let first = info.split(separator: " ").first,
                      let pid = Int32(first.replacingOccurrences(of: "workerPID=", with: "")) else { return 1 }
                let cancelledInference = Task {
                    try await QwenRuntime.shared.transcribe(audio.samples, language: "Chinese", variant: .qwen4bit)
                }
                try await Task.sleep(for: .milliseconds(10))
                let cancelStart = Date()
                cancelledInference.cancel()
                _ = await cancelledInference.result
                await QwenRuntime.shared.unload()
                guard kill(pid, 0) == -1, errno == ESRCH else { return 1 }
                print("Cancelled inference worker exited seconds=\(Date().timeIntervalSince(cancelStart))")
                return 0
            }
            if let index = arguments.firstIndex(of: "--download-speech-model") {
                guard arguments.count > index + 1,
                      let variant = SpeechModel(rawValue: arguments[index + 1]), variant.isQwen else {
                    throw ASRModelError.manifest
                }
                let manifest = try variant.manifest()
                try await ASRModelInstaller().install(manifest) { _, _, _ in }
                try await ASRModelInstaller().verify(manifest)
                print("Downloaded and SHA256-verified: \(variant.rawValue) (\(manifest.totalBytes) bytes)")
                return 0
            }
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
                let locale = arguments.count > index + 2 && !arguments[index + 2].hasPrefix("--") ? arguments[index + 2] : "zh-CN"
                let variant: SpeechModel
                if let modelIndex = arguments.firstIndex(of: "--speech-model") {
                    guard arguments.count > modelIndex + 1, let parsed = SpeechModel(rawValue: arguments[modelIndex + 1]) else {
                        throw ASRModelError.manifest
                    }
                    variant = parsed
                } else { variant = .apple }
                let engine: any SpeechRecognizing = variant == .apple ? SpeechEngine() : QwenSpeechEngine(variant: variant)
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
    private static func memoryReport(_ label: String) { print("\(label) | \(memoryDescription())") }

    private static func memoryDescription() -> String {
        let usage = Qwen3ASRSTT.memoryUsage()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = status == KERN_SUCCESS ? String(format: "%.1f", Double(info.phys_footprint) / 1_048_576) : "unavailable"
        return "MLX active=\(usage.active) cache=\(usage.cache) peak=\(usage.peak) footprintMiB=\(footprint)"
    }

    private static func runQwenWorker(_ variant: SpeechModel) async -> Int32 {
        func respond(text: String? = nil, error: String? = nil) throws {
            var data = try JSONEncoder().encode(QwenWorkerResponse(text: text, error: error, memory: memoryDescription()))
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        do {
            try await InProcessQwenRuntime.shared.prepare(variant)
            try respond()
            var pending = Data()
            while true {
                let chunk = try QwenWorkerIO.read(.standardInput)
                if chunk.isEmpty { break }
                pending.append(chunk)
                guard pending.count < 16 * 1024 * 1024 else { throw ASRModelError.tooLong }
                while let end = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: end)
                    let request = try JSONDecoder().decode(QwenWorkerRequest.self, from: line)
                    pending.removeSubrange(...end)
                    guard request.audio.count <= QwenAudioBuffer.maxSamples,
                          request.audio.allSatisfy(\.isFinite) else { throw ASRModelError.tooLong }
                    let text = try await InProcessQwenRuntime.shared.transcribe(request.audio, language: request.language, variant: variant)
                    try respond(text: text)
                }
            }
            await InProcessQwenRuntime.shared.unload()
            return 0
        } catch {
            try? respond(error: error.localizedDescription)
            return 1
        }
    }

}
