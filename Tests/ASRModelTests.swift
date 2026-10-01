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
        precondition(SpeechModel.allCases.count == 5 && SpeechModel.allCases[0] == .apple)
        precondition(!SpeechModel.apple.emitsLivePartial)
        for model in SpeechModel.allCases where model.isLocal {
            precondition(model.emitsLivePartial)
            precondition(model.preemptsLivePartial == model.isNative)
        }
        for model in [SpeechModel.senseVoice, .funASRNano] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Sources/Resources/ASR/\(model.rawValue).json"))
            let manifest = try JSONDecoder().decode(ASRModelManifest.self, from: data)
            try manifest.validate()
            precondition(model.isLocal && model.isNative && !model.isQwen)
            precondition(model.emitsLivePartial)
            precondition(model.preemptsLivePartial)
            precondition(model.supports(locale: Locale(identifier: "zh-CN")))
            precondition(!model.supports(locale: Locale(identifier: "fr-FR")))
        }
        precondition(SpeechHotwords.context(" Codex, Saylane，Codex\n提分侠 ") == "Codex、Saylane、提分侠")
        precondition(SpeechHotwords.context(" , \n") == nil)
        precondition(SpeechHotwords.context(String(repeating: "长", count: 2000))?.count == 80)
        for language in AppLanguage.allCases { _ = try QwenLanguage.name(for: language.speechLocale) }
        precondition(QwenLanguage.normalize("学习软件", locale: Locale(identifier: "zh-TW")) == "學習軟件")
        precondition(QwenLanguage.normalize("學習軟件", locale: Locale(identifier: "zh-CN")) == "学习软件")
        precondition(QwenLanguage.normalize("Hello", locale: Locale(identifier: "en-US")) == "Hello")
        do { _ = try QwenLanguage.name(for: Locale(identifier: "xx")); fatalError("unsupported locale accepted") }
        catch ASRModelError.unsupportedLanguage {}

        let storedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("asr-stored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storedRoot) }
        let currentManifest = try SpeechModel.qwen4bit.manifest()
        let storedParent = currentManifest.directory(root: storedRoot).deletingLastPathComponent()
        let obsoleteRevision = storedParent.appendingPathComponent(String(repeating: "9", count: 40), isDirectory: true)
        try FileManager.default.createDirectory(at: obsoleteRevision, withIntermediateDirectories: true)
        let hasObsoleteRevision = try ASRModelStore.hasStoredData(.qwen4bit, root: storedRoot)
        precondition(hasObsoleteRevision, "an obsolete revision must remain visible to the cleanup UI")
        try FileManager.default.removeItem(at: obsoleteRevision)
        let hasStoredDataAfterRemoval = try ASRModelStore.hasStoredData(.qwen4bit, root: storedRoot)
        precondition(!hasStoredDataAfterRemoval)

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

        // A retry must reserve space only for files that are still missing. A
        // fully verified file in the revision's .partial directory has already
        // consumed its on-disk bytes and will be reused by install().
        let largerData = Data("12345".utf8)
        let largerDigest = SHA256.hash(data: largerData).map { String(format: "%02x", $0) }.joined()
        let largerFile = ASRModelManifest.File(name: "config.json", size: Int64(largerData.count),
                                               sha256: largerDigest, repository: nil, revision: nil)
        let capacityManifest = ASRModelManifest(
            id: manifest.id, repository: manifest.repository, revision: manifest.revision,
            license: manifest.license, files: [file, largerFile]
        )
        let capacityRoot = root.appendingPathComponent("capacity")
        let retryStaging = capacityRoot.appendingPathComponent("\(manifest.revision).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: retryStaging, withIntermediateDirectories: true)
        let freshCapacity = try ASRModelInstaller.additionalBytesNeeded(capacityManifest, staging: retryStaging)
        precondition(freshCapacity == 100_000_000 + capacityManifest.totalBytes,
                     "fresh download must reserve remaining model bytes exactly once plus the safety margin")
        try data.write(to: retryStaging.appendingPathComponent(file.name))
        let resumedCapacity = try ASRModelInstaller.additionalBytesNeeded(capacityManifest, staging: retryStaging)
        precondition(freshCapacity - resumedCapacity == file.size,
                     "verified bytes already present in .partial must be deducted exactly once")
        try Data("abd".utf8).write(to: retryStaging.appendingPathComponent(file.name))
        let corruptCapacity = try ASRModelInstaller.additionalBytesNeeded(capacityManifest, staging: retryStaging)
        precondition(corruptCapacity == freshCapacity,
                     "same-size corrupt partial files must still reserve replacement and temporary bytes")

        // Repair publication must use safe-save replacement. A missing staging
        // directory forces the real filesystem operation to fail; the installed
        // destination and its contents must still be intact afterwards.
        let publishRoot = root.appendingPathComponent("publish", isDirectory: true)
        let publishDestination = publishRoot.appendingPathComponent("revision", isDirectory: true)
        try FileManager.default.createDirectory(at: publishDestination, withIntermediateDirectories: true)
        let installedMarker = publishDestination.appendingPathComponent("installed")
        try Data("old".utf8).write(to: installedMarker)
        let missingStaging = publishRoot.appendingPathComponent("missing.partial", isDirectory: true)
        do {
            try ASRModelInstaller.publish(staging: missingStaging, to: publishDestination)
            fatalError("missing staging directory replaced a working model")
        } catch {}
        let preservedMarker = try Data(contentsOf: installedMarker)
        precondition(preservedMarker == Data("old".utf8),
                     "failed publication must preserve the working destination")

        let replacementStaging = publishRoot.appendingPathComponent("replacement.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementStaging, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: replacementStaging.appendingPathComponent("installed"))
        try ASRModelInstaller.publish(staging: replacementStaging, to: publishDestination)
        let publishedMarker = try Data(contentsOf: publishDestination.appendingPathComponent("installed"))
        precondition(publishedMarker == Data("new".utf8),
                     "successful repair must publish the verified staging directory")
        precondition(!FileManager.default.fileExists(atPath: replacementStaging.path),
                     "safe-save replacement must consume the staging directory")

        // Exercise the actual installer with a deterministic transport (no large network downloads).
        let installRoot = root.appendingPathComponent("install")
        let installParent = installRoot.appendingPathComponent(manifest.id, isDirectory: true)
        let oldRevision = String(repeating: "b", count: 40)
        let oldPartialRevision = String(repeating: "c", count: 40) + ".partial"
        let oldDirectory = installParent.appendingPathComponent(oldRevision, isDirectory: true)
        let oldPartialDirectory = installParent.appendingPathComponent(oldPartialRevision, isDirectory: true)
        let unrelatedDirectory = installParent.appendingPathComponent("keep-user-data", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("external-revision", isDirectory: true)
        let revisionSymlink = installParent.appendingPathComponent(String(repeating: "d", count: 40))
        let revisionRegularFile = installParent.appendingPathComponent(String(repeating: "e", count: 40))
        for directory in [oldDirectory, oldPartialDirectory, unrelatedDirectory, externalDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: revisionSymlink, withDestinationURL: externalDirectory)
        try Data("unrelated".utf8).write(to: revisionRegularFile)
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
        precondition(!FileManager.default.fileExists(atPath: oldDirectory.path),
                     "successful install must remove superseded 40-hex revisions")
        precondition(!FileManager.default.fileExists(atPath: oldPartialDirectory.path),
                     "successful install must remove superseded 40-hex .partial revisions")
        precondition(FileManager.default.fileExists(atPath: unrelatedDirectory.path),
                     "revision cleanup must preserve unrelated model data")
        precondition(FileManager.default.fileExists(atPath: revisionSymlink.path),
                     "revision cleanup must never follow or remove symbolic links")
        precondition(FileManager.default.fileExists(atPath: revisionRegularFile.path),
                     "revision cleanup must preserve regular files even when their names match")
        let badRoot = root.appendingPathComponent("bad-download")
        let badParent = badRoot.appendingPathComponent(manifest.id, isDirectory: true)
        let previousBeforeFailure = badParent.appendingPathComponent(oldRevision, isDirectory: true)
        try FileManager.default.createDirectory(at: previousBeforeFailure, withIntermediateDirectories: true)
        let badInstaller = ASRModelInstaller(root: badRoot, fetch: { url, _ in
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try Data("abd".utf8).write(to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { try await badInstaller.install(manifest) { _, _, _ in }; fatalError("bad download installed") }
        catch ASRModelError.checksum {}
        precondition(!manifest.isInstalled(root: badRoot))
        precondition(FileManager.default.fileExists(atPath: previousBeforeFailure.path),
                     "failed install must preserve the previously downloaded revision")

        // Once the new revision is published, reclaiming an inaccessible old
        // revision is best-effort. Cleanup failure must not reverse or misreport
        // the successful install.
        let cleanupFailureRoot = root.appendingPathComponent("cleanup-failure")
        let cleanupFailureParent = cleanupFailureRoot.appendingPathComponent(manifest.id, isDirectory: true)
        let lockedOldRevision = cleanupFailureParent.appendingPathComponent(oldRevision, isDirectory: true)
        let lockedChild = lockedOldRevision.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedChild, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: lockedChild.appendingPathComponent("model"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedChild.path)
        let cleanupFailureInstaller = ASRModelInstaller(root: cleanupFailureRoot, fetch: { url, _ in
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        try await cleanupFailureInstaller.install(manifest) { _, _, _ in }
        precondition(manifest.isInstalled(root: cleanupFailureRoot),
                     "old-revision cleanup failure must not reverse a successful publish")
        precondition(FileManager.default.fileExists(atPath: lockedOldRevision.path),
                     "the test must exercise a real cleanup failure")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedChild.path)

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
        do { try audio.append(input); fatalError("unbounded recording") } catch is SpeechLengthLimitReached {}
        precondition(audio.samples.count == QwenAudioBuffer.maxSamples, "overflow must not silently truncate and submit")
        print("PASS: ASR manifests, immutable URLs, hashes, retry capacity, atomic publication, revision cleanup, partial installs, symlinks, languages, PCM ownership, resampling and duration cap")
    }
}
