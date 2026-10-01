# Changelog

All notable user-facing changes. Older design diaries that used to serve as change records live under `docs/history/`.

## 0.2.81 (local testing)

- Fixed every button in Saylane's own windows (onboarding, settings) ignoring clicks since 0.2.79. The mouse monitors added in 0.2.79 read `keyCode` from mouse events, which raises an exception; AppKit swallowed it together with the click. Found on device in 0.2.80, which was otherwise unverified.

## 0.2.80 (local testing)

Reliability pass: typing and dictation must work in every text field before anything else is tuned.

### Dictation reaches every application

- A press starts recording at once in any application and under any input source. Saylane no longer switches the input source, waits for the application to attach, or switches back; the whole wake/reconnect/restore state machine is gone. On-device traces showed that Electron applications (Codex, Claude) often never activate a newly selected input method, so that wait could not succeed there.
- The finished text is written at the caret of the application the dictation started in, through the first route that works: the attached input-method client; otherwise a paste (⌘V, after which the previous clipboard contents are restored; needs Accessibility); otherwise it is left on the clipboard with a notice saying so. A dictation is never dropped because "there is no text field".
- A click or a focus move inside the application during a dictation no longer cancels it. The inline preview is withdrawn and continues in the HUD; the result lands where the caret is when it is ready. Switching to another application stops the recording; the result is never written into the other application and is left on the clipboard unless you come back before it is ready.
- Typing after the key is released no longer discards the dictation. A bare modifier (Shift, ⌘…) is not typing; Return, arrows, shortcuts and text typed on past the 450 ms wait go to the application at once, and the result is written when it is ready. Previously each of these cancelled the dictation, most of them without a notice.
- "Copy Last Dictation" in the input-method menu retrieves the most recent result.
- Removed the settings "说完后回到原来的输入法" and "不支持组字的应用改用粘贴写入": neither choice exists any more. Accessibility is listed first among the optional permissions, with what it is for.

### Typing

- The pinyin session is bound to the activation of an input-method controller, not to the identity of the proxy object IMK passes with each callback, and every key first makes sure the session of its own client is the active one. A key can no longer reach an engine without a session because of callback order or a different proxy object.
- A key that cannot be handled (no receiver) is passed to the application instead of being swallowed.

### Engineering

- `VoiceSessionController` is about 300 lines (was 785); `FocusedTextTarget` holds the write routes and is tested without IMK, event posting or the pasteboard.
- Saylane's own pasted ⌘V is tagged and ignored by its event tap. The paste key follows the active keyboard layout. Two pastes in quick succession restore the user's own clipboard, not the first dictation.
- `make pkg-local` builds `dist/Saylane-<version>-local.pkg` for testing on this Mac (unsigned package). `make pkg` remains the signed and notarized release path.
- The diagnostic trace keeps 300 entries and records the write route of each dictation (`voice-target`, `delivery`).

Not yet verified on device.

## 0.2.79 (source audit; local validation)

- Keep IMK writes and deferred typing bound to the exact client lease and focus generation. An insert callback caused by Saylane's own final commit no longer invalidates the next Pinyin keystroke; stale callbacks cannot write into a newly focused field.
- Preserve the authoritative recognition tail. Optional polishing yields its complete ordinary result as soon as typing resumes. Printable input waits at most 450 ms for final recognition, then cancels that dictation with a notice and resumes typing. Command, navigation, Return and deletion keys remain on their original IMK callback. Accessibility fallback cancels a pending voice write when the user continues typing.
- Keep the current input source when the user resumes typing so automatic restoration cannot interrupt a new Pinyin composition. Observe accepted source transitions and retain bounded receipts for cancelled or timed-out requests; late ABC bridge or restore requests receive one compensating source selection.
- Fix global-tap lock ordering, stale-worker teardown, cross-producer duplicate handling, and observe-versus-filter permission reporting. A short right-Command tap or chord now discards preroll immediately, preserving double-tap recognition without carrying old ambient audio into the next utterance.
- Drain queued audio on release, finalize at the utterance limit, keep cancellation cleanup isolated, and recover local ASR after failed previews. Model installation accounts only for missing download bytes, publishes atomically, and leaves failed old-revision cleanup visible.
- Preserve short OCR labels, bind the voice HUD to its original display, make settings trials use the current text, and keep unfinished onboarding resumable. Merge legacy data without overwriting conflicts and migrate a proofreading key only after the replacement was saved successfully.
- Preserve the live app until Installer has validated its replacement, sequence input-mode activation and uninstall correctly, and require stable application signing, installer signing, notarization and staple verification before a final package is published. All signing configuration is checked before a signing key is accessed.
- Add deterministic tests for IME focus epochs, reentrant final insertion, bounded typing, late source requests, preroll teardown, audio ownership, model storage, and installer contracts. Refresh English localization from compiler-generated strings. Commands and test logs use Asia/Shanghai.

This is a source/build validation candidate. It has not been installed for a new cross-application acceptance run, and no 0.2.79 distribution package has been produced.

## 0.2.78 (local testing)

- Keep the active IMK controller and its exact text client alive, initialize pinyin for clients attached during launch, and prevent late callbacks from committing another client's composition.
- Recover a selected-but-disconnected input source once before reporting failure. Match the client to the focused application, and cancel when focus or input source changes.
- Synchronize recording and wake-up state with the hotkey router, including tap-to-talk stop, Esc, and disabled-input-method behavior.
- Preserve queued and pre-recorded audio on key-up, stop recording immediately during client attachment, and report relay overflow instead of silently losing words.
- Use the settings trial field only while that page is focused. Stop its microphone meter when settings loses focus or closes.
- Bind optional Accessibility insertion to the captured field, preserve complete clipboard contents, and report insertion failures accurately.
- Add Swift 6 tests for the full voice controller, reconnect/restore, focus loss, quick release, recording-state routing, and commit failure.

## 0.2.77 (local testing)

- Fixed the input method exiting as soon as voice input or the microphone meter started. The audio callback now runs outside MainActor, as required by AVAudioEngine under Swift 6.
- Added Swift 6 debug/release regression tests for background audio callbacks and an explicit `--microphone-check` diagnostic that exercises three capture/stop cycles without saving audio.

## 0.2.76 (unreleased build for local testing)

Ground-up rework of the app's orchestration layer following `docs/REFACTOR_PLAN.md`. The default trigger key (right ⌥) and every existing gesture are unchanged; existing settings, models and the Rime user dictionary carry over.

### Voice input

- The microphone opens the moment the trigger key goes down. Audio is buffered while the hold is confirmed, the input source switches and the recognizer loads, so the first words of an utterance are no longer lost.
- A press while another input method is active switches to Saylane, and switches **back** when the utterance ends (setting: "说完后回到原来的输入法", on by default).
- Apps that never attach an input-method client (terminals, some Electron fields) get a clear message within one second instead of a silent three-second wait. An optional Accessibility-based paste fallback can write the final text there (setting: "不支持组字的应用改用粘贴写入", off by default, needs the Accessibility permission).
- The bottom HUD shows the state word (准备中 / 正在听 / 正在整理 / AI 润色中), the recognized text and the translation, and failure reasons in the same capsule. Blocked starts never open the settings window any more.
- Switching apps no longer cancels a session unless the app that owns the text field lost focus; notification banners and Spotlight are ignored.
- Local models hitting the 30-second limit commit what was heard instead of discarding the utterance.
- Changing the language pair reloads models once instead of twice.
- Translation-model downloads no longer require the settings window to be open; a small window appears only while a download is pending.

### Screen translation

- The pinned result is a floating, draggable, non-activating panel. Other apps stay usable while it is open; it no longer activates the input-method host (which used to cancel dictation and commit pinyin).
- Freezing the rest of the screen while pinned is now a setting, off by default.
- The long-press left ⌃ entry is now a setting, off by default; ⌥T (configurable) is the entry point.
- The shortcut recorder validates chords: a modifier is required, at most three keys, system-reserved combinations are refused, and risky ones warn.
- Esc cancels a selection from anywhere; Tab / ⌘C / D / R work once the pin is clicked.

### Pinyin

- Every input-method client has its own Rime session, so switching windows no longer commits one window's composition into another.
- The candidate bar follows the caret at its real position and falls back to the pointer, never to a screen corner.
- The Latin layout override happens once per client, not on every key.
- Removed the "联想" preference; the shipped schema never supported it.
- The input-method menu links to the Rime user dictionary directory.

### Setup and settings

- Onboarding: permissions one at a time with auto-advance, an "optional extras" page (input monitoring, speech recognition, screen recording, accessibility) with a one-line reason per permission, a microphone level meter on the trial page, and an Apple Dictation conflict hint for fn / ⌃ triggers.
- The settings window no longer polls permissions every second; it refreshes on focus and on system notifications.
- Errors that need action show once in the HUD and stay as a banner (with a "去处理" button) until resolved; the input-method menu also shows them.
- The Wikimedia glossary download is now opt-in (default off) and explains what it fetches when enabled.
- Upgrades no longer re-run onboarding; an `onboardingVersion` replaces the per-release flag.

### Storage

- All app data now lives in `~/Library/Application Support/Saylane/` (`ASRModels`, `Diagnostics`, `Rime`, `Glossary`). The old `RTranslate/` directory is moved on first launch and still read if the move fails.
- The Keychain service for the proofreading key is `com.saylane.final-polish`; old items migrate on first use.

### Engineering

- Swift 6 language mode with complete strict concurrency across the app target.
- `AppModel` shrank from 1039 to about 600 lines and is now a composition root; features live in `Core/`, `Input/`, `Voice/`, `Screen/`, with `PermissionsController` and `ScreenFeature` owning their flows.
- All preferences go through `PreferencesStore`; `UserDefaults` is no longer read anywhere else (enforced by `Tests/BrandingTests.py`).
- One `GestureArbiter` recognises every gesture from one event stream with duplicate suppression; `InputEventRouter` owns the hold timers.
- New unit tests: gesture arbiter, shortcut validator, input router, preferences store and migration, readiness reducer, preroll capture.
- UI strings are routed through a String Catalog (`Localizable.xcstrings`) with Simplified Chinese as the source and an English localization.

## 0.2.75 and earlier

See the GitHub release notes and `docs/history/`.
