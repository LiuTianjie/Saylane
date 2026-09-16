import Foundation
import Translation

enum TranslationEngineError: LocalizedError {
    case notReady
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notReady: return "翻译模型还没准备好。"
        case .unsupported: return "系统不支持这对语言。"
        }
    }
}

@MainActor
@Observable
final class TranslationEngine {
    private(set) var isReady = false
    private(set) var needsDownload = false
    var isPassthrough = false
    var session: TranslationSession?
    private var generation = 0
    private var outputLocale: Locale?

    func reset() {
        generation += 1
        session = nil
        isReady = false
        needsDownload = false
        isPassthrough = false
        outputLocale = nil
    }

    func enablePassthrough() {
        isPassthrough = true
        isReady = true
        needsDownload = false
        session = nil
    }

    func attach(_ session: TranslationSession) async throws {
        let token = generation
        try await session.prepareTranslation()
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        self.session = session
        isReady = true
        needsDownload = false
    }

    func prepareInstalled(source: Locale.Language, target: Locale.Language) async throws {
        let token = generation
        outputLocale = Locale(identifier: target.maximalIdentifier)
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        switch status {
        case .installed:
            let session = TranslationSession(installedSource: source, target: target)
            try await session.prepareTranslation()
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
            self.session = session
            isReady = true
            needsDownload = false
        case .supported:
            isReady = false
            needsDownload = true
        case .unsupported:
            throw TranslationEngineError.unsupported
        @unknown default:
            throw TranslationEngineError.unsupported
        }
    }

    /// Preserve IDs because batch responses need not arrive in request order.
    func translateBatch(_ texts: [String]) async throws -> [String] {
        if isPassthrough { return texts }
        guard let session else { throw TranslationEngineError.notReady }
        let token = generation
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        var results = Array<String?>(repeating: nil, count: texts.count)
        for response in responses {
            guard let id = response.clientIdentifier, let index = Int(id), results.indices.contains(index) else { continue }
            results[index] = outputLocale.map { QwenLanguage.normalize(response.targetText, locale: $0) } ?? response.targetText
        }
        guard results.allSatisfy({ $0 != nil }) else { throw TranslationEngineError.notReady }
        return results.map { $0! }
    }

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isPassthrough { return trimmed }
        guard let session else { throw TranslationEngineError.notReady }
        let response = try await session.translate(trimmed)
        let text = response.targetText
        if let outputLocale {
            return QwenLanguage.normalize(text, locale: outputLocale)
        }
        return text
    }
}
