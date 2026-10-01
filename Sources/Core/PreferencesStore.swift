import Foundation
import Observation

/// Key-value backing so the store can be tested without touching real defaults.
protocol PreferencesBacking: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func persistentDomain(forName name: String) -> [String: Any]?
}

extension UserDefaults: PreferencesBacking {}

final class InMemoryPreferencesBacking: PreferencesBacking {
    var storage: [String: Any]
    var legacyDomains: [String: [String: Any]]
    init(_ storage: [String: Any] = [:], legacyDomains: [String: [String: Any]] = [:]) {
        self.storage = storage
        self.legacyDomains = legacyDomains
    }
    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
    func persistentDomain(forName name: String) -> [String: Any]? { legacyDomains[name] }
}

/// The only writer of persisted preferences. Each field keeps the key it always
/// had, so upgrading users keep their settings; migrations run once in `init`.
@MainActor @Observable
final class PreferencesStore {
    private(set) var current: Preferences
    @ObservationIgnored private let backing: PreferencesBacking

    enum Key {
        static let sourceLanguage = "sourceLanguage"
        static let targetLanguage = "targetLanguage"
        static let pairSource = "pairSourceLanguage"
        static let pairTarget = "pairTargetLanguage"
        static let pushToTalk = "pushToTalkHotkey"
        static let tapToTalk = "tapToTalk"
        static let languageSwitchEnabled = "languageSwitchEnabled"
        static let overlayEnabled = "overlayEnabled"
        static let speechModel = "speechModel"
        static let recognitionOnly = "recognitionOnly"
        static let speechHotwordsEnabled = "speechHotwordsEnabled"
        static let speechHotwords = "speechHotwords"
        static let dictationCleanupEnabled = "dictationCleanupEnabled"
        static let dictationGlossaryEnabled = "dictationGlossaryEnabled"
        static let finalPolishEnabled = "finalPolishEnabled"
        static let finalPolishEndpoint = "finalPolishEndpoint"
        static let finalPolishModel = "finalPolishModel"
        static let screenPolishEnabled = "screenPolishEnabled"
        static let screenCaptureKeyCode = "screenCaptureKeyCode"
        static let screenCaptureModifiers = "screenCaptureModifiers"
        static let screenHoldEnabled = "screenHoldEnabled"
        static let screenPinFreezesScreen = "screenPinFreezesScreen"
        static let screenFontWeightExperiment = "screenFontWeightExperiment"
        static let screenTranslateSource = "screenTranslateSource"
        static let screenTranslateTarget = "screenTranslateTarget"
        static let pinyinEnglishMode = "pinyinEnglishMode"
        static let pinyinBarPreeditEnabled = "pinyinBarPreeditEnabled"
        static let pinyinFuzzyEnabled = "pinyinFuzzyEnabled"
        static let onboardingVersion = "onboardingVersion"
        /// Pre-0.3 flag. Read once for migration, never written again.
        static let legacySetupVerified = "setupVerifiedV7"
        static let legacyDomain = "com.rtranslate.app"
    }

    init(backing: PreferencesBacking = UserDefaults.standard) {
        self.backing = backing
        Self.migrateLegacyDomain(backing)
        current = Self.load(backing)
        Self.migrateOnboardingFlag(backing, into: &current)
    }

    /// Apply one change. Only keys whose value changed are written.
    func update(_ mutate: (inout Preferences) -> Void) {
        var next = current
        mutate(&next)
        guard next != current else { return }
        let previous = current
        current = next
        Self.save(next, previous: previous, to: backing)
    }

    // MARK: - Migration

    private static func migrateLegacyDomain(_ backing: PreferencesBacking) {
        // Carry only product preferences across the input-method bundle-ID migration.
        let legacy = backing.persistentDomain(forName: Key.legacyDomain) ?? [:]
        for key in [Key.sourceLanguage, Key.targetLanguage, Key.pushToTalk, Key.overlayEnabled] {
            if backing.object(forKey: key) == nil, let value = legacy[key] {
                backing.set(value, forKey: key)
            }
        }
    }

    private static func migrateOnboardingFlag(_ backing: PreferencesBacking, into preferences: inout Preferences) {
        guard backing.object(forKey: Key.onboardingVersion) == nil,
              backing.object(forKey: Key.legacySetupVerified) as? Bool == true else { return }
        preferences.onboardingVersion = Preferences.currentOnboardingVersion
        backing.set(preferences.onboardingVersion, forKey: Key.onboardingVersion)
    }

    // MARK: - Load

    private static func load(_ b: PreferencesBacking) -> Preferences {
        var p = Preferences()
        func string(_ key: String) -> String? { b.object(forKey: key) as? String }
        func bool(_ key: String, default value: Bool) -> Bool { b.object(forKey: key) as? Bool ?? value }
        func language(_ key: String) -> AppLanguage? { string(key).flatMap(AppLanguage.init(rawValue:)) }

        p.sourceLanguage = language(Key.sourceLanguage) ?? p.sourceLanguage
        p.targetLanguage = language(Key.targetLanguage) ?? p.targetLanguage
        p.pairSource = language(Key.pairSource) ?? p.sourceLanguage
        p.pairTarget = language(Key.pairTarget)
            ?? (p.targetLanguage != p.sourceLanguage ? p.targetLanguage : (p.sourceLanguage == .en ? .zhHans : .en))
        p.pushToTalk = string(Key.pushToTalk).flatMap(PushToTalkHotkey.init(rawValue:)) ?? p.pushToTalk
        p.tapToTalk = bool(Key.tapToTalk, default: p.tapToTalk)
        p.languageSwitchEnabled = bool(Key.languageSwitchEnabled, default: p.languageSwitchEnabled)
        p.overlayEnabled = bool(Key.overlayEnabled, default: p.overlayEnabled)
        p.speechModel = string(Key.speechModel).flatMap(SpeechModel.init(rawValue:)) ?? p.speechModel
        p.recognitionOnly = bool(Key.recognitionOnly, default: p.recognitionOnly)
        p.speechHotwordsEnabled = bool(Key.speechHotwordsEnabled, default: p.speechHotwordsEnabled)
        p.speechHotwords = string(Key.speechHotwords) ?? p.speechHotwords
        p.dictationCleanupEnabled = bool(Key.dictationCleanupEnabled, default: p.dictationCleanupEnabled)
        p.dictationGlossaryEnabled = bool(Key.dictationGlossaryEnabled, default: p.dictationGlossaryEnabled)
        p.finalPolishEnabled = bool(Key.finalPolishEnabled, default: p.finalPolishEnabled)
        p.finalPolishEndpoint = string(Key.finalPolishEndpoint) ?? p.finalPolishEndpoint
        p.finalPolishModel = string(Key.finalPolishModel) ?? p.finalPolishModel
        p.screenPolishEnabled = bool(Key.screenPolishEnabled, default: p.screenPolishEnabled)
        if let key = b.object(forKey: Key.screenCaptureKeyCode) as? Int {
            let flags = (b.object(forKey: Key.screenCaptureModifiers) as? Int).map(UInt64.init)
                ?? ScreenCaptureShortcut.optionT.modifierFlags
            let shortcut = ScreenCaptureShortcut(keyCode: UInt16(clamping: key), modifierFlags: flags)
            p.screenCaptureShortcut = shortcut.isUsable ? shortcut : .optionT
        }
        p.screenHoldEnabled = bool(Key.screenHoldEnabled, default: p.screenHoldEnabled)
        p.screenPinFreezesScreen = bool(Key.screenPinFreezesScreen, default: p.screenPinFreezesScreen)
        p.screenFontWeightExperiment = bool(Key.screenFontWeightExperiment, default: p.screenFontWeightExperiment)
        p.screenTranslateSource = language(Key.screenTranslateSource)
        p.screenTranslateTarget = language(Key.screenTranslateTarget)
        p.pinyinEnglishMode = bool(Key.pinyinEnglishMode, default: p.pinyinEnglishMode)
        p.pinyinBarPreeditEnabled = bool(Key.pinyinBarPreeditEnabled, default: p.pinyinBarPreeditEnabled)
        p.pinyinFuzzyEnabled = bool(Key.pinyinFuzzyEnabled, default: p.pinyinFuzzyEnabled)
        p.onboardingVersion = b.object(forKey: Key.onboardingVersion) as? Int ?? p.onboardingVersion
        return p
    }

    // MARK: - Save

    private static func save(_ p: Preferences, previous o: Preferences, to b: PreferencesBacking) {
        func put<T: Equatable>(_ new: T, _ old: T, _ key: String, _ value: (T) -> Any?) {
            guard new != old else { return }
            if let stored = value(new) { b.set(stored, forKey: key) } else { b.removeObject(forKey: key) }
        }
        put(p.sourceLanguage, o.sourceLanguage, Key.sourceLanguage) { $0.rawValue }
        put(p.targetLanguage, o.targetLanguage, Key.targetLanguage) { $0.rawValue }
        put(p.pairSource, o.pairSource, Key.pairSource) { $0.rawValue }
        put(p.pairTarget, o.pairTarget, Key.pairTarget) { $0.rawValue }
        put(p.pushToTalk, o.pushToTalk, Key.pushToTalk) { $0.rawValue }
        put(p.tapToTalk, o.tapToTalk, Key.tapToTalk) { $0 }
        put(p.languageSwitchEnabled, o.languageSwitchEnabled, Key.languageSwitchEnabled) { $0 }
        put(p.overlayEnabled, o.overlayEnabled, Key.overlayEnabled) { $0 }
        put(p.speechModel, o.speechModel, Key.speechModel) { $0.rawValue }
        put(p.recognitionOnly, o.recognitionOnly, Key.recognitionOnly) { $0 }
        put(p.speechHotwordsEnabled, o.speechHotwordsEnabled, Key.speechHotwordsEnabled) { $0 }
        put(p.speechHotwords, o.speechHotwords, Key.speechHotwords) { $0 }
        put(p.dictationCleanupEnabled, o.dictationCleanupEnabled, Key.dictationCleanupEnabled) { $0 }
        put(p.dictationGlossaryEnabled, o.dictationGlossaryEnabled, Key.dictationGlossaryEnabled) { $0 }
        put(p.finalPolishEnabled, o.finalPolishEnabled, Key.finalPolishEnabled) { $0 }
        put(p.finalPolishEndpoint, o.finalPolishEndpoint, Key.finalPolishEndpoint) { $0 }
        put(p.finalPolishModel, o.finalPolishModel, Key.finalPolishModel) { $0 }
        put(p.screenPolishEnabled, o.screenPolishEnabled, Key.screenPolishEnabled) { $0 }
        if p.screenCaptureShortcut != o.screenCaptureShortcut {
            b.set(Int(p.screenCaptureShortcut.keyCode), forKey: Key.screenCaptureKeyCode)
            b.set(Int(p.screenCaptureShortcut.modifierFlags), forKey: Key.screenCaptureModifiers)
        }
        put(p.screenHoldEnabled, o.screenHoldEnabled, Key.screenHoldEnabled) { $0 }
        put(p.screenPinFreezesScreen, o.screenPinFreezesScreen, Key.screenPinFreezesScreen) { $0 }
        put(p.screenFontWeightExperiment, o.screenFontWeightExperiment, Key.screenFontWeightExperiment) { $0 }
        put(p.screenTranslateSource, o.screenTranslateSource, Key.screenTranslateSource) { $0?.rawValue }
        put(p.screenTranslateTarget, o.screenTranslateTarget, Key.screenTranslateTarget) { $0?.rawValue }
        put(p.pinyinEnglishMode, o.pinyinEnglishMode, Key.pinyinEnglishMode) { $0 }
        put(p.pinyinBarPreeditEnabled, o.pinyinBarPreeditEnabled, Key.pinyinBarPreeditEnabled) { $0 }
        put(p.pinyinFuzzyEnabled, o.pinyinFuzzyEnabled, Key.pinyinFuzzyEnabled) { $0 }
        put(p.onboardingVersion, o.onboardingVersion, Key.onboardingVersion) { $0 }
    }
}
