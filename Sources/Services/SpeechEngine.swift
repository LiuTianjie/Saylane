import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechEngine: SpeechRecognizing {
    var onPartial: ((String) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Error>?
    private let converter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?
    private var finalized = ""
    private var generation = 0

    static func resolvedLocale(for locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return match
        }
        return SpeechLocale.bestMatch(for: locale, in: await SpeechTranscriber.supportedLocales)
    }

    static func isInstalled(for locale: Locale) async -> Bool {
        guard let resolved = await resolvedLocale(for: locale) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }
    }

    static func prepareModel(for locale: Locale) async throws {
        // Return revisable hypotheses with a smaller context window for live input.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        try await ensureModel(for: transcriber, locale: locale)
    }

    func begin(locale: Locale) async throws {
        guard let locale = await Self.resolvedLocale(for: locale) else { throw SpeechEngineError.unsupportedLocale }
        try Task.checkCancellation()
        finalized = ""
        generation += 1
        let token = generation

        // Return revisable hypotheses with a smaller context window for live input.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard await Self.isInstalled(for: locale) else { throw SpeechEngineError.setupFailed }
        try Task.checkCancellation()

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.invalidFormat
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        recognizerTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    guard token == self.generation else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalized += text
                        let snapshot = self.finalized
                        self.onPartial?(snapshot)
                    } else {
                        let snapshot = self.finalized + text
                        self.onPartial?(snapshot)
                    }
                }
            } catch {
                throw error
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) throws {
        guard let analyzerFormat, let inputBuilder else { return }
        do {
            let converted = try converter.convertBuffer(buffer, to: analyzerFormat)
            let input: AVAudioPCMBuffer
            if converted === buffer {
                guard let copy = PCMCopy.copy(buffer) else { return }
                input = copy
            } else {
                input = converted
            }
            inputBuilder.yield(AnalyzerInput(buffer: input))
        } catch {
            throw error
        }
    }

    func finish() async throws -> String {
        // Keep accepting final results until the analyzer and result stream drain.
        inputBuilder?.finish()
        if let analyzer {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        try await recognizerTask?.value
        generation += 1
        recognizerTask = nil
        let result = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        analyzerFormat = nil
        return result
    }

    func cancel() async {
        generation += 1
        inputBuilder?.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        recognizerTask?.cancel()
        recognizerTask = nil
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        analyzerFormat = nil
        finalized = ""
    }

    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = Set((await SpeechTranscriber.installedLocales).map { $0.identifier(.bcp47) })
        if !installed.contains(locale.identifier(.bcp47)) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            do {
                try await AssetInventory.reserve(locale: locale)
            } catch {
                NSLog("Saylane: could not reserve locale \(locale.identifier): \(error.localizedDescription)")
            }
        }
    }
}
