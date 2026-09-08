import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case es = "es"
    case de = "de"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .es: return "Español"
        case .de: return "Deutsch"
        }
    }

    var shortName: String {
        switch self {
        case .zhHans: return "中文"
        case .zhHant: return "繁中"
        case .en: return "EN"
        case .ja: return "JA"
        case .ko: return "KO"
        case .fr: return "FR"
        case .es: return "ES"
        case .de: return "DE"
        }
    }

    var speechLocale: Locale {
        Locale(identifier: speechIdentifier)
    }

    var speechIdentifier: String {
        switch self {
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .en: return "en-US"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        case .fr: return "fr-FR"
        case .es: return "es-ES"
        case .de: return "de-DE"
        }
    }

    var translationLanguage: Locale.Language {
        Locale(identifier: rawValue).language
    }
}

enum SpeechLocale {
    static func bestMatch(for locale: Locale, in candidates: [Locale]) -> Locale? {
        let ordered = candidates.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        let wanted = locale.identifier(.bcp47)
        if let exact = ordered.first(where: { $0.identifier(.bcp47) == wanted }) {
            return exact
        }
        guard let language = locale.language.languageCode?.identifier else { return nil }
        if let region = locale.language.region?.identifier,
           let regional = ordered.first(where: {
               $0.language.languageCode?.identifier == language
                   && $0.language.region?.identifier == region
           }) {
            return regional
        }
        return ordered.first { $0.language.languageCode?.identifier == language }
    }
}

struct TranslationDirection: Equatable, Hashable, Identifiable {
    let source: AppLanguage
    let target: AppLanguage
    var id: String { source.rawValue + ">" + target.rawValue }
    var reversed: Self { Self(source: target, target: source) }

    var title: String {
        if source == target { return "\(source.displayName)听写" }
        return "\(source.shortName) → \(target.shortName)"
    }

    var compactTitle: String {
        if source == target { return "\(source.shortName) 听写" }
        return "\(source.shortName) → \(target.shortName)"
    }

    /// Four directions from the two languages chosen in settings:
    /// A→A, A→B, B→A, B→B.
    static func voiceModes(a: AppLanguage, b: AppLanguage) -> [TranslationDirection] {
        let raw = [
            TranslationDirection(source: a, target: a),
            TranslationDirection(source: a, target: b),
            TranslationDirection(source: b, target: a),
            TranslationDirection(source: b, target: b)
        ]
        var seen = Set<String>()
        return raw.filter { seen.insert($0.id).inserted }
    }

    static func cycled(current: TranslationDirection, a: AppLanguage, b: AppLanguage) -> TranslationDirection {
        let modes = voiceModes(a: a, b: b)
        if let index = modes.firstIndex(of: current) {
            return modes[(index + 1) % modes.count]
        }
        return modes[min(1, modes.count - 1)]
    }
}
