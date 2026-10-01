import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechEngine: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Error>?
    /// The dictation model's results, used only until the speech model has said something.
    private var earlyTask: Task<Void, Never>?
    private var speechModelSpoke = false
    private let converter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?
    private var finalized = ""
    private var hasAudioSignal = false
    private var generation = 0
    private let contextualStrings: [String]

    /// `contextualStrings` are the user's names and terms; they bias recognition only.
    init(contextualStrings: [String] = []) { self.contextualStrings = contextualStrings }

    static func resolvedLocale(for locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return match
        }
        return SpeechLocale.bestMatch(for: locale, in: await SpeechTranscriber.supportedLocales)
    }

    /// The system's dictation model for this language, when it is already on
    /// the Mac. It answers after about half a second where the speech model
    /// takes a whole one (measured on the same recording: 530 ms against
    /// 1020 ms), so it supplies the first words of the preview. The text that
    /// is written always comes from the speech model.
    private static func earlyModule(for locale: Locale) async -> DictationTranscriber? {
        let wanted = locale.identifier(.bcp47)
        guard await DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == wanted }) else { return nil }
        return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
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
        hasAudioSignal = false
        speechModelSpoke = false
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

        let early = await Self.earlyModule(for: locale)
        let modules: [any SpeechModule] = early.map { [transcriber, $0] } ?? [transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer

        guard await Self.isInstalled(for: locale) else { throw SpeechEngineError.setupFailed }
        try Task.checkCancellation()
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            do { try await analyzer.setContext(context) } catch {
                // Bias is best effort; recognition proceeds and vocabulary repair still runs.
                NSLog("Saylane: contextual strings not applied: \(error.localizedDescription)")
            }
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
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
                    guard self.hasAudioSignal else { continue }
                    let text = String(result.text.characters)
                    if !text.isEmpty { self.speechModelSpoke = true }
                    if result.isFinal {
                        self.finalized += text
                        self.onPartial?(SpeechHypothesis(stableText: self.finalized))
                    } else {
                        self.onPartial?(SpeechHypothesis(stableText: self.finalized, volatileText: text))
                    }
                }
            } catch {
                throw error
            }
        }

        if let early {
            earlyTask = Task { [weak self] in
                do {
                    for try await result in early.results {
                        guard let self, token == self.generation else { return }
                        // Only the first words: once the speech model has an answer, it is the preview.
                        if self.speechModelSpoke { return }
                        guard self.hasAudioSignal else { continue }
                        let text = String(result.text.characters)
                        if !text.isEmpty { self.onPartial?(SpeechHypothesis(volatileText: text)) }
                    }
                } catch {
                    // The preview then starts with the speech model's first answer, as before.
                }
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) throws {
        guard let analyzerFormat, let inputBuilder else { return }
        do {
            let converted = try converter.convertBuffer(buffer, to: analyzerFormat)
            hasAudioSignal = hasAudioSignal || AudioLevel.hasSignal(in: converted)
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
        // SpeechAnalyzer can hallucinate words on all-zero audio. Cancel rather
        // than accepting a final transcript for a recording with no signal.
        if !hasAudioSignal {
            await cancel()
            return ""
        }
        // Keep accepting final results until the analyzer and result stream drain.
        inputBuilder?.finish()
        if let analyzer {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        try await recognizerTask?.value
        generation += 1
        recognizerTask = nil
        earlyTask?.cancel()
        earlyTask = nil
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
        earlyTask?.cancel()
        earlyTask = nil
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        analyzerFormat = nil
        finalized = ""
        hasAudioSignal = false
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
