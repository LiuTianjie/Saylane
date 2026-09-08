import AVFoundation
import CryptoKit
import Foundation

@main struct ASRModelTests {
    static func main() async throws {
        for (model, expected) in [(SpeechModel.qwen4bit, Int64(724209413)), (.qwen6bit, Int64(873205701))] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Sources/Resources/ASR/\(model.rawValue).json"))
            let manifest = try JSONDecoder().decode(ASRModelManifest.self, from: data)
            try manifest.validate()
            precondition(manifest.totalBytes == expected)
            precondition(manifest.url(for: manifest.files[0]).path.contains(manifest.revision))
            precondition(manifest.directory().path.hasPrefix(ASRModelManifest.root.path))
            precondition(!manifest.directory().path.contains(".app/"))
        }
        precondition(SpeechModel.allCases.count == 3 && SpeechModel.allCases[0] == .apple)
        for language in AppLanguage.allCases { _ = try QwenLanguage.name(for: language.speechLocale) }
        precondition(QwenLanguage.normalize("学习软件", locale: Locale(identifier: "zh-TW")) == "學習軟件")
        precondition(QwenLanguage.normalize("學習軟件", locale: Locale(identifier: "zh-CN")) == "学习软件")
        precondition(QwenLanguage.normalize("Hello", locale: Locale(identifier: "en-US")) == "Hello")
        do { _ = try QwenLanguage.name(for: Locale(identifier: "xx")); fatalError("unsupported locale accepted") }
        catch ASRModelError.unsupportedLanguage {}

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("abc".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = ASRModelManifest.File(name: "model.safetensors", size: 3, sha256: digest, repository: nil, revision: nil)
        let manifest = ASRModelManifest(id: SpeechModel.qwen4bit.rawValue,
            repository: "mlx-community/Qwen3-ASR-0.6B-4bit", revision: String(repeating: "a", count: 40),
            license: "Apache-2.0", files: [file])
        let dir = manifest.directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.name)
        try data.write(to: url)
        let valid = try ASRModelInstaller.verifyFile(url, file: file)
        precondition(valid)
        precondition(!manifest.isInstalled(root: root), "incomplete downloads must not be selectable")
        try manifest.revision.write(to: dir.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        precondition(manifest.isInstalled(root: root))
        try await ASRModelInstaller(root: root).verify(manifest)
        try Data("abd".utf8).write(to: url)
        let corrupt = try ASRModelInstaller.verifyFile(url, file: file)
        precondition(!corrupt, "same-size corruption must fail SHA256")
        do { try await ASRModelInstaller(root: root).verify(manifest); fatalError("corruption accepted") }
        catch ASRModelError.checksum {}
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("external")
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        precondition(!manifest.isInstalled(root: root))
        let symbolic = try ASRModelInstaller.verifyFile(url, file: file)
        precondition(!symbolic)
        let unsafe = ASRModelManifest(id: manifest.id, repository: manifest.repository, revision: manifest.revision,
                                     license: manifest.license, files: [file, .init(name: "../escape", size: 1, sha256: digest, repository: nil, revision: nil)])
        do { try unsafe.validate(); fatalError("path traversal accepted") } catch ASRModelError.manifest {}

        // Exercise the actual installer with a deterministic transport (no large network downloads).
        let installRoot = root.appendingPathComponent("install")
        let installer = ASRModelInstaller(root: installRoot, fetch: { url, progress in
            precondition(url.host == "huggingface.co" && url.path.contains(manifest.revision))
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary)
            progress(Int64(data.count))
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        try await installer.install(manifest) { _, _, _ in }
        precondition(manifest.isInstalled(root: installRoot))
        try await installer.verify(manifest)
        precondition(!FileManager.default.fileExists(atPath: manifest.directory(root: installRoot).path + ".partial"))
        let badRoot = root.appendingPathComponent("bad-download")
        let badInstaller = ASRModelInstaller(root: badRoot, fetch: { url, _ in
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try Data("abd".utf8).write(to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { try await badInstaller.install(manifest) { _, _, _ in }; fatalError("bad download installed") }
        catch ASRModelError.checksum {}
        precondition(!manifest.isInstalled(root: badRoot))
        let cancelRoot = root.appendingPathComponent("cancelled")
        let cancellingInstaller = ASRModelInstaller(root: cancelRoot, fetch: { _, _ in
            try await Task.sleep(for: .seconds(10))
            throw ASRModelError.missing
        })
        let task = Task { try await cancellingInstaller.install(manifest) { _, _, _ in } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { try await task.value; fatalError("cancelled download succeeded") } catch is CancellationError {}
        precondition(!manifest.isInstalled(root: cancelRoot))

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        input.frameLength = 1600
        for i in 0..<1600 { input.floatChannelData![0][i] = 0.25 }
        let audio = QwenAudioBuffer()
        try audio.append(input)
        input.floatChannelData![0][0] = 0.9
        precondition(audio.samples.count == 1600 && audio.samples[0] == 0.25)
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let stereoInput = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4800)!
        stereoInput.frameLength = 4800
        for c in 0..<2 { for i in 0..<4800 { stereoInput.floatChannelData![c][i] = 0.25 } }
        let resampled = QwenAudioBuffer()
        try resampled.append(stereoInput)
        precondition(abs(resampled.samples.count - 1600) < 10)
        precondition(resampled.samples.allSatisfy(\.isFinite))
        for _ in 1..<300 { try audio.append(input) }
        precondition(audio.samples.count == QwenAudioBuffer.maxSamples)
        do { try audio.append(input); fatalError("unbounded recording") } catch ASRModelError.tooLong {}
        precondition(audio.samples.count == QwenAudioBuffer.maxSamples, "overflow must not silently truncate and submit")
        print("PASS: ASR manifests, immutable URLs, hashes, partial installs, symlinks, languages, PCM ownership, resampling and duration cap")
    }
}
