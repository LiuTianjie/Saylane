import AppKit
import Carbon.HIToolbox

@main struct PreferencesStoreTests {
    @MainActor static func main() {
        // Fresh install: defaults, and the trigger key stays right Option.
        do {
            let backing = InMemoryPreferencesBacking()
            let store = PreferencesStore(backing: backing)
            precondition(store.current == Preferences())
            precondition(store.current.pushToTalk == .rightOption)
            precondition(store.current.dictationGlossaryEnabled == false, "network access is opt-in")
            precondition(store.current.screenPinFreezesScreen == false)
            precondition(!store.current.onboardingCompleted)
            precondition(backing.storage.isEmpty, "nothing is written until something changes")
        }
        // The default direction changed in 0.4.2 (write what is said). A new
        // installation gets it; someone who used Saylane before and never chose
        // a language keeps "write English".
        do {
            precondition(Preferences().sourceLanguage == .zhHans && Preferences().targetLanguage == .zhHans && Preferences().translationIsPassthrough)
            let existing = InMemoryPreferencesBacking(["onboardingVersion": 1])
            precondition(PreferencesStore(backing: existing).current.targetLanguage == .en && existing.storage["targetLanguage"] as? String == "en")
            let chosen = InMemoryPreferencesBacking(["onboardingVersion": 1, "targetLanguage": "ja"])
            precondition(PreferencesStore(backing: chosen).current.targetLanguage == .ja)
        }
        // A setting of a feature that is gone (the Control long-press) is removed from storage.
        do {
            let backing = InMemoryPreferencesBacking(["screenHoldEnabled": true, "sourceLanguage": "en"])
            let store = PreferencesStore(backing: backing)
            precondition(backing.storage["screenHoldEnabled"] == nil && store.current.sourceLanguage == .en)
            precondition(backing.storage.count == 1, "\(backing.storage)")
        }
        // Upgrade: every pre-0.3 key is read under its old name.
        do {
            let backing = InMemoryPreferencesBacking([
                "sourceLanguage": "en", "targetLanguage": "zh-Hans",
                "pairSourceLanguage": "en", "pairTargetLanguage": "ja",
                "pushToTalkHotkey": "rightCommand", "tapToTalk": true, "languageSwitchEnabled": false,
                "overlayEnabled": false, "speechModel": "sensevoice-small-q8", "recognitionOnly": true,
                "speechHotwordsEnabled": true, "speechHotwords": "Saylane|赛兰", "dictationCleanupEnabled": false,
                "dictationGlossaryEnabled": true, "finalPolishEnabled": true, "finalPolishEndpoint": "https://x/v1",
                "finalPolishModel": "m", "screenPolishEnabled": true,
                "screenCaptureKeyCode": Int(kVK_ANSI_S), "screenCaptureModifiers": Int(ScreenModifier.command | ScreenModifier.option),
                "screenTranslateSource": "ja", "screenTranslateTarget": "en",
                "pinyinEnglishMode": true, "pinyinBarPreeditEnabled": true, "pinyinFuzzyEnabled": false,
                "setupVerifiedV7": true
            ])
            let store = PreferencesStore(backing: backing)
            let p = store.current
            // "Recognize only" was on: what is spoken is what is written.
            precondition(p.sourceLanguage == .en && p.targetLanguage == .en && p.pairSource == .en && p.pairTarget == .ja)
            precondition(backing.object(forKey: "recognitionOnly") == nil)
            precondition(p.pushToTalk == .rightCommand && p.tapToTalk && !p.languageSwitchEnabled && !p.overlayEnabled)
            precondition(p.speechModel == .senseVoice && p.speechHotwordsEnabled && p.speechHotwords == "Saylane|赛兰")
            precondition(!p.dictationCleanupEnabled && p.dictationGlossaryEnabled && p.finalPolishEnabled)
            precondition(p.finalPolishEndpoint == "https://x/v1" && p.finalPolishModel == "m" && p.screenPolishEnabled)
            precondition(p.screenCaptureShortcut.keyCode == UInt16(kVK_ANSI_S) && p.screenCaptureShortcut.normalizedFlags == (ScreenModifier.command | ScreenModifier.option))
            precondition(p.screenTranslateSource == .ja && p.screenTranslateTarget == .en)
            precondition(p.pinyinEnglishMode && p.pinyinBarPreeditEnabled && !p.pinyinFuzzyEnabled)
            // The old flag stood for the first guide; the 0.4 welcome page is shown once more.
            precondition(p.onboardingVersion == 1 && !p.onboardingCompleted, "setupVerifiedV7 migrates to onboardingVersion 1")
            precondition(backing.storage["onboardingVersion"] as? Int == 1)
        }
        // An unusable stored screen shortcut falls back to ⌥T.
        do {
            let backing = InMemoryPreferencesBacking(["screenCaptureKeyCode": Int(kVK_ANSI_T), "screenCaptureModifiers": 0])
            precondition(PreferencesStore(backing: backing).current.screenCaptureShortcut == .optionT)
        }
        // Legacy bundle-domain values migrate only when nothing newer exists.
        do {
            let backing = InMemoryPreferencesBacking(["overlayEnabled": true],
                legacyDomains: ["com.rtranslate.app": ["pushToTalkHotkey": "leftOption", "overlayEnabled": false]])
            let store = PreferencesStore(backing: backing)
            precondition(store.current.pushToTalk == .leftOption && store.current.overlayEnabled)
        }
        // Writes: only changed keys, under the compatible names; no-op updates write nothing.
        do {
            let backing = InMemoryPreferencesBacking()
            let store = PreferencesStore(backing: backing)
            store.update { $0.pairSource = .ja; $0.pairTarget = .en; $0.sourceLanguage = .ja; $0.targetLanguage = .en }
            // The pair's target already equals its default: only the three changed keys are written.
            precondition(Set(backing.storage.keys) == ["pairSourceLanguage", "sourceLanguage", "targetLanguage"])
            store.update { $0.pairSource = .ja }
            precondition(backing.storage.count == 3)
            store.update { $0.screenCaptureShortcut = ScreenCaptureShortcut(keyCode: UInt16(kVK_ANSI_S), modifierFlags: ScreenModifier.command | ScreenModifier.option) }
            precondition(backing.storage["screenCaptureKeyCode"] as? Int == Int(kVK_ANSI_S))
            store.update { $0.screenTranslateSource = .en }
            precondition(backing.storage["screenTranslateSource"] as? String == "en")
            store.update { $0.screenTranslateSource = nil }
            precondition(backing.storage["screenTranslateSource"] == nil)
            // Round trip.
            let reloaded = PreferencesStore(backing: backing)
            precondition(reloaded.current == store.current)
        }
        print("PASS: preferences defaults, legacy key migration, onboarding flag migration, minimal writes and round trip")
    }
}
