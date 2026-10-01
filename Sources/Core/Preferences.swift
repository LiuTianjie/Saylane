import Foundation

/// Every user-facing setting, as one value. Fields are the only source of truth;
/// `PreferencesStore` persists them and nothing else in the app touches `UserDefaults`.
struct Preferences: Equatable, Sendable {
    // Languages
    // A new installation writes what is said, in the language it is said in.
    // Translating is a choice: pick another language to write, or double-tap
    // right ⌘ to go round the pair below.
    var sourceLanguage: AppLanguage = .zhHans
    var targetLanguage: AppLanguage = .zhHans
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
    /// A short sound when listening starts and stops.
    var voiceCuesEnabled = true
    /// The microphone to use; nil is the system's default.
    var microphoneUID: String?
    /// How the finished text is written.
    var dictationDropFinalStop = false
    var dictationSpaceBetweenScripts = false

    // Recognition
    var speechModel: SpeechModel = .apple
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
    var pinyinKeys = PinyinKeyOptions()

    // The welcome page. Bump `Preferences.currentOnboardingVersion` only when
    // existing users should see it once more (2: the 0.4 page, where the
    // input method is added in place and nothing is a wizard any more).
    var onboardingVersion = 0

    static let currentOnboardingVersion = 2
    var onboardingCompleted: Bool { onboardingVersion >= Self.currentOnboardingVersion }

    var currentDirection: TranslationDirection { TranslationDirection(source: sourceLanguage, target: targetLanguage) }
    var translationIsPassthrough: Bool { sourceLanguage == targetLanguage }
}
