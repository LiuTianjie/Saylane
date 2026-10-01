# Changelog

All notable user-facing changes. Older design diaries that used to serve as change records live under `docs/history/`.

## 0.4.2 (local testing)

- Installing no longer resets any privacy grant. 0.4.1's installer removed the grants held under the input method's identity, and on device macOS deleted the main program's microphone, screen recording and Accessibility grants along with them — the two identities are tied together. The microphone had to be allowed again and screen recording has to be allowed once more. Grants are now removed only by `scripts/uninstall.sh`.
- Electron applications deliver every modifier change to the input method twice (seen on device); the copy is no longer reported or forwarded.
- A build running in a test home no longer listens to the mouse of the person using the Mac: their clicks were voiding the talk key of the two-process self-test.
- Confirmed on device with 0.4.1: holding the talk key with the microphone not yet allowed raises the system's question on the spot, and allowing it takes effect at once; the installer's restart of the system's input-menu programs works.

## 0.4.1 (local testing)

- The application icon is the original one again. 0.4.0 replaced it by mistake: only the input-source icon — the one in the menu bar and next to the caret when you switch — looked like another input method's, and only that one changes.
- Installing now cleans up after the previous version. The system's own input-menu programs keep an input method's icon in memory until they restart, which is why the old icon was still shown after 0.4.0 was installed; the installer restarts those three programs (the system starts them again by itself). It also reset the privacy grants held under the input method's identity, which turned out to delete the main program's as well — withdrawn in 0.4.2.
- The trace file of the one-process builds (`Diagnostics/input-session.json`) is deleted.
- The input method starts the installed main program by its path, not whichever copy with the same identifier the system happens to know.
- `scripts/uninstall.sh` leaves nothing in the session or the privacy lists; `--purge` also removes settings, the pinyin user dictionary, models and traces.
- Packaging removes the staging folders of earlier versions.

## 0.4.0 (local testing)

The part of Saylane you see was carried over unchanged by the 0.3 rewrite. This release redoes it, measured against how mature input methods behave (Doubao's installer registers, enables and selects its input source by itself, and it has no permission wizard).

### First run

- After an installation Saylane adds itself to the input sources and switches to itself. Nobody is sent to System Settings for that; the pane is opened only if macOS has not gone along after eight seconds. With Accessibility allowed (the talk key works under every input method) the current input method is left alone.
- The four-step guide is gone. One welcome page: the practice field, three status rows — input method, microphone, Accessibility — each with the one button that settles it, and "Start". Existing users see it once.
- The microphone is asked for where it is first needed: hold the talk key before it was ever requested and macOS asks, right there. No page has to be visited first.
- Another input method being the current one no longer refuses a dictation. Found on device within a minute of installing 0.3.0: the practice field answered three presses with "Saylane is not the selected input method". The key had arrived; there was a place to write. It is now a state shown in the input-method row, with a "Switch to Saylane" button.

### Icon

- The input-menu icon looked like another input method's: a black disc with five white bars. It is now Saylane's own mark, a speech bubble with a text cursor cut out of it. Six generations of unused experimental icon files no longer ship in the input method.

### Typing

- Emoji no longer take the first places. The engine puts each picture right behind the word it illustrates (可以 🙆‍♂️ 🙆‍♀️ 🉑 刻意 可疑); one per word is kept, behind the words on the first page.

### Removed

- Screen translation by long-pressing left Control, with its setting. ⌥T and the input-method menu remain.

### Engineering

- A build running in a test home reads, and never changes, which input sources are registered, enabled or selected on the Mac.
- Design previews render through a real hosting view (scroll views do not draw in `ImageRenderer`).

Not done, and said plainly: whole-sentence accuracy is behind Doubao's, which uses a large language model. Two open n-gram models for Rime were tried in a scratch copy (41 MB and 409 MB); each fixed some sentences and broke others, one of them badly, so neither ships.

Verified on the development Mac: all tests and the three self-tests of the built programs. Still to be confirmed on device: the automatic adding and selecting of the input source on a Mac where it is not yet enabled, and the microphone prompt at first use.

## 0.3.0 (local testing)

Saylane is rewritten as two programs. Design and reasons: `docs/DESIGN_0.3.md`; structure: `docs/ARCHITECTURE.md`.

### Two programs

- **The input method** (`/Library/Input Methods/Saylane.app`) types pinyin and writes text into the focused field. It asks for no permission, opens no window and loads no model.
- **The main program** (`/Applications/Saylane.app`) does everything else: the talk key, recording, recognition, translation, proofreading, the capsule, screen translation, settings and the guide. It has no Dock icon; ⌘Q closes its window and leaves it running. The input method starts it when it is needed and not there; once Accessibility is allowed it also starts at login (a switch in Settings), so the talk key works before Saylane has been selected.
- Typing no longer depends on anything the main program does. It keeps working while a model loads, when macOS asks to "Quit & Reopen" after a permission is granted, and when the main program is quit or crashes: a dictation in progress is released and the keys that were waiting for it are typed.
- Why: macOS counts how often an input method's process exits. From the eleventh exit within thirty minutes every running application is told the input method "has crashed" and stops using it until that application is relaunched — the input menu then shows no Saylane submenu, and neither pinyin nor dictation works there. Found on device with WeChat on 2026-10-01. In 0.2.x every installation, every permission restart and every crash of any feature counted. The input-method process now exits once per upgrade and at no other time.

### After upgrading from 0.2.x

- Allow the microphone again: the main program is a new application to macOS, and the guide opens for it after the installation. Screen Recording and Speech Recognition likewise, when you use them.
- Relaunch any application in which Saylane had stopped working (see above). Nothing else can clear that mark.

### The talk key

- One state machine for every modifier (as introduced in 0.2.83): held on its own for 0.12 s the microphone opens silently, at 0.28 s the dictation starts. A key, a click or a second modifier in between voids the press until the key is released.
- A key or a click while you are speaking is an interruption: within 1.5 s the press was a shortcut and nothing is kept; later the recording stops and what was said is put on the clipboard instead of at a caret that may have moved.
- Tap-to-talk starts on the release of a clean tap, so a shortcut can no longer start it.
- A release that never arrives (the application swallowed it) no longer leaves the microphone open: the physical key state is checked while you speak.
- A modifier used as the talk key is no longer hidden from applications.
- **Accessibility** (recommended) makes the talk key work in every application and under every input source. Without it the key works where Saylane is the selected input source and the caret is in a text field. Input Monitoring is no longer asked for.

### Where the text goes

- A dictation belongs to the application that has the keyboard, not merely the one in front. Spotlight, launchers and other floating panels are written through the input method like any text field.
- Applications that host their text fields in a helper process (Lark reports `com.electron.lark.helper`) are recognised as themselves.
- Unchanged: input method → paste (needs Accessibility; the clipboard is restored) → clipboard with a notice. Another application coming to the front, or a panel closing, never gets the text; it is kept on the clipboard.

### Engineering

- `Sources/Shared/` holds the contract: Codable messages over two local `CFMessagePort`s. The input method decides about every key by itself from the last state it was sent and never waits for the main program; state is always pushed whole.
- The gesture handlers `InputShortcutHandler`, `PushToTalkHandler` and `GlobalHotkeyRouter` are replaced by `VoiceGesture`.
- Diagnostics are per process: `Diagnostics/ime.json` and `Diagnostics/app.json`; identical consecutive entries are merged.
- `make verify` builds the release, runs every test and three self-tests of the built programs in a scratch home (`SAYLANE_TEST_HOME`): the input method against a text client in its own process, a whole dictation across both programs with a scripted recognizer, and the interface with real clicks. `scripts/verify-staged.sh` repeats the self-tests on the signed bundles that go into the package.
- The installer carries both bundles. It never kills the input method before the payload is in place and ends the old process exactly once afterwards.

Verified on the development Mac: all tests and the three self-tests, also on the signed bundles of the package. Not verifiable there and still to be confirmed on device: InputMethodKit's transport from other applications to the new process, the permission prompts of the new application, the installer scripts running as root, the microphone and the recognizers.

## 0.2.83 (local testing)

- The talk key is hold-to-talk on every modifier: it starts only after the key has been held on its own for about 0.3 s. ⌘W, ⌘C, ⌥←, ⇧A, a modified click or a second modifier never start a dictation, never open the microphone and never show the capsule. With ⌘, ⌃ or ⇧ as the talk key the microphone opens when the hold is confirmed, not on every key press.
- Screen translation by holding left Control no longer exits the moment you start dragging: the click that draws the selection was being read as "cancel" (a 0.2.79 change that only took effect once 0.2.81 repaired the mouse monitor).
- Focus and input-source changes no longer re-query every permission and retry the global key listener each time; the diagnostics file is no longer flooded with identical "global-tap failed" lines.

## 0.2.82 (local testing)

- The bottom capsule shows only the waveform while you speak, as it did in 0.2.75. The state word, the language label and the recognized/translated text lines added in 0.2.76–0.2.79 are gone, together with the "show text in the hint" setting.

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
