import Foundation

/// Every user-facing setting, as one value. Fields are the only source of truth;
/// `PreferencesStore` persists them and nothing else in the app touches `UserDefaults`.
struct Preferences: Equatable, Sendable {
    // Languages
    var sourceLanguage: AppLanguage = .zhHans
    var targetLanguage: AppLanguage = .en
    var pairSource: AppLanguage = .zhHans
    var pairTarget: AppLanguage = .en

    // Voice trigger
    var pushToTalk: PushToTalkHotkey = .rightOption
    var tapToTalk = false
    var languageSwitchEnabled = true

    /// Start the main program at login, so the talk key works under any input
    /// method without switching to Saylane first. Applies once Accessibility is allowed.
    var launchAtLogin = true

    // HUD
    var overlayEnabled = true

    // Recognition
    var speechModel: SpeechModel = .apple
    var recognitionOnly = false
    var speechHotwordsEnabled = false
    var speechHotwords = ""
    var dictationCleanupEnabled = true
    /// Wikimedia harvest is network access from an input method; off until the user opts in.
    var dictationGlossaryEnabled = false

    // Final polish (LLM)
    var finalPolishEnabled = false
    var finalPolishEndpoint = ""
    var finalPolishModel = ""
    var screenPolishEnabled = false

    // Screen translate
    var screenCaptureShortcut: ScreenCaptureShortcut = .optionT
    /// Long-press left Control to start a selection. Off by default: terminal
    /// users hold Control before deciding what to press.
    /// Block pointer input to other apps while a pin is visible.
    var screenPinFreezesScreen = false
    var screenFontWeightExperiment = true
    var screenTranslateSource: AppLanguage?
    var screenTranslateTarget: AppLanguage?

    // Pinyin
    var pinyinEnglishMode = false
    var pinyinBarPreeditEnabled = false
    var pinyinFuzzyEnabled = true

    // The welcome page. Bump `Preferences.currentOnboardingVersion` only when
    // existing users should see it once more (2: the 0.4 page, where the
    // input method is added in place and nothing is a wizard any more).
    var onboardingVersion = 0

    static let currentOnboardingVersion = 2
    var onboardingCompleted: Bool { onboardingVersion >= Self.currentOnboardingVersion }

    var currentDirection: TranslationDirection { TranslationDirection(source: sourceLanguage, target: targetLanguage) }
    var translationIsPassthrough: Bool { recognitionOnly || sourceLanguage == targetLanguage }
}
