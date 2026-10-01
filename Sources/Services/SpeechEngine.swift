import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
final class SpeechEngine: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Error>?
    /// The dictation model's results: the words on screen while you speak.
    private var earlyTask: Task<Void, Never>?
    private var earlyFinalized = ""
    private var earlyVolatile = ""
    /// How far into the recording each model's latest answer reaches, in seconds.
    private var earlyHeard = 0.0
    private var speechHeard = 0.0
    private var speechVolatile = ""
    /// Called for every stretch the speech model settles: where it ends in the recording, and its text.
    var onSegment: ((_ end: Double, _ text: String) -> Void)?
    /// The dictation model may be this far behind the speech model before the preview stops following it.
    private static let earlyMayTrail = 1.5
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
    /// the Mac. It is the preview: it answers about every 0.3 s, where the
    /// speech model answers once a second, several characters at a time
    /// (measured on recordings replayed in real time: 29–31 updates against
    /// 11–12 over the same eleven seconds). The text that is written always
    /// comes from the speech model, which makes fewer mistakes.
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
        earlyFinalized = ""; earlyVolatile = ""; speechVolatile = ""
        earlyHeard = 0; speechHeard = 0
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
                    self.speechHeard = max(self.speechHeard, Self.end(of: result.range))
                    if result.isFinal {
                        self.finalized = Self.tidy(self.finalized + text)
                        self.speechVolatile = ""
                        if !text.isEmpty { self.onSegment?(Self.end(of: result.range), Self.tidy(text)) }
                    } else {
                        self.speechVolatile = text
                    }
                    self.emitPreview()
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
                        guard self.hasAudioSignal else { continue }
                        let text = String(result.text.characters)
                        self.earlyHeard = max(self.earlyHeard, Self.end(of: result.range))
                        if result.isFinal {
                            self.earlyFinalized += text
                            self.earlyVolatile = ""
                        } else {
                            self.earlyVolatile = text
                        }
                        self.emitPreview()
                    }
                } catch {
                    // The preview then follows the speech model alone.
                    guard let self, token == self.generation else { return }
                    self.earlyFinalized = ""; self.earlyVolatile = ""; self.earlyHeard = 0
                }
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// The preview follows the dictation model while it keeps up, and the speech model otherwise.
    private func emitPreview() {
        let early = earlyFinalized + earlyVolatile
        if !early.isEmpty, speechHeard - earlyHeard < Self.earlyMayTrail {
            onPartial?(SpeechHypothesis(stableText: Self.tidy(earlyFinalized), volatileText: earlyVolatile))
        } else if !(finalized + speechVolatile).isEmpty {
            onPartial?(SpeechHypothesis(stableText: finalized, volatileText: speechVolatile))
        }
    }

    private static func end(of range: CMTimeRange) -> Double {
        let seconds = range.end.seconds
        return seconds.isFinite ? seconds : 0
    }

    /// The speech model puts a space in front of Chinese punctuation ("欢迎 ，并与"). Not in what is shown or written.
    static func tidy(_ text: String) -> String {
        guard text.contains(" ") else { return text }
        return text.replacingOccurrences(of: "(?<=[\\p{Han}，。！？；：、])[ \\t]+(?=[，。！？；：、])|(?<=[，。！？；：、])[ \\t]+(?=\\p{Han})",
                                         with: "", options: .regularExpression)
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

extension SpeechEngine: SegmentingSpeechRecognizing {}
