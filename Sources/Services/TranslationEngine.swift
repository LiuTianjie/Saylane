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

    func reset() {
        generation += 1
        session = nil
        isReady = false
        needsDownload = false
        isPassthrough = false
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

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isPassthrough { return trimmed }
        guard let session else { throw TranslationEngineError.notReady }
        let response = try await session.translate(trimmed)
        return response.targetText
    }
}
