# Changelog

All notable user-facing changes. Older design diaries that used to serve as change records live under `docs/history/`.

## 0.7.1 (local testing)

- The pin's toolbar has one copy button, and it copies the picture. "Copy" and "Full text" stood side by side and read as a single "Copy Full text"; the full-text popover and its "Copy Text" are gone.
- The timing of a dictation no longer takes the start sound for the speaker's voice.
- Copies of a pin are logged (`screen-copy`).

Looked at and left as it was: giving the pin the keyboard as soon as it appears (so ⌘C works without a click). It takes the keyboard away from the application in front and detaches the input method from its text field; that was not what was asked for.

Seen on device with 0.7.0: dictations written by Qwen3-ASR every time, text 0.30–0.48 s after the release; seven screen translations, the largest with 109 blocks, 84 of them translated in place, one set smaller, none cut; recognition 0.6–0.95 s and measuring 0.02–0.10 s per capture.

## 0.7.0 (local testing)

Screen translation is redone: the translation is set where the original was, as if the interface had switched language. Design, scoring and what is still missing: `docs/SCREEN_TRANSLATE_V2.md`.

### Screen translation

- Size, weight and colour of every line are measured from the pixels of the capture instead of being guessed from the recogniser's boxes. On 24 samples with ground truth (Apple support, GitHub Docs, MDN, Vue, and an application interface of our own, light and dark, 1x and 2x) the median font-size error went from 17.4% — the old pipeline set everything almost a fifth too large — to 0.9%; 86% of the blocks are within 5%.
- Only the strokes of the original are erased. Background, icons, pictures and the edges of buttons and bubbles stay pixel for pixel. No blurred patches, no plates, no scrolling inside a block.
- The translation keeps the original's alignment and line pitch. When it does not fit it uses the free space the pixels show, then a smaller size, and is cut only as a last resort. English to Chinese: one block in 544 had to be set smaller. Chinese to English is the hard direction (the containers were drawn for the Chinese): 17% smaller, 6% cut.
- The pin shows two pictures, the capture and its translation; Tab switches, ⌘C copies the one on screen.
- A capture larger than 2200 points (a whole 1x screen) is read a second time in tiles, so small type is not lost.
- From releasing the mouse to the picture: about 1.3–2 s on the development Mac at 1x (recognition 0.55 s, measuring 0.3 s, translation 0.4–1.2 s).

### Removed

- "On-device font weight detection" (Settings → Screen Translation) and its Core ML model: weight is always measured now.

### Not done, and said plainly

- Wording: Apple's on-device translation works sentence by sentence and gets interface terms wrong ("Share" → 份额, "Live" → 过) and translates logos. A translation that sees the whole screen is designed and not built.
- Icons are sometimes read as letters; a link or a bold word inside a paragraph loses its own style; serif type is set in sans.
- All samples are web pages and an interface of our own. Native applications, chat applications and video frames have not been scored: that needs the feature on a real screen.
- The live region (subtitles, chat) is designed only.

Verified on the development Mac: all tests, the three self-tests, the scoring harness, and pictures through the application's own path (`--pin-snapshot`). Not yet on device: 0.6.1, 0.6.2 and this.

## 0.6.2 (local testing)

"Is the pre-processing and post-processing state of the art? Are there better models?" Measured, not argued: `docs/SPEECH_PIPELINE.md` §5–7 lists what can go wrong between the mouth and the screen, what Doubao and Typeless do about each case, and what was tried here.

### Recording

- The recording no longer ends the instant the key goes up. People release the key while the last syllable is still in the air: on 60 recordings, ending 0.15 s before the last syllable does left 25 sentences right instead of 38, and 0.3 s left 8. Saylane now keeps listening for at least 0.1 s after the release, goes on while a voice is heard, and ends once it has been quiet for 0.12 s, or after 0.5 s. The text arrives that much later.
- A quiet recording is brought up to an ordinary level before the downloaded model hears it (30 dB too quiet cost it about a fifth more mistakes).

### Writing

- More numbers are written the way the system writes them: thousands ("40,000"), percentages ("百分之二十" → "20%") and times with minutes ("十一点三十五分" → "11:35"). An hour alone is left as the model wrote it: 两点 is also "two points", and the system guessed "2:00" for "在两点之间的运动". "M16" stays one name instead of becoming "M 16". On 54 real sentences with numbers, wholly right: system recognizer 6, model alone 4, together 16.

### Models, measured and not adopted

- Other families of about the same size, same recordings: Fun-ASR-Nano is as accurate as Qwen3-ASR 0.6B and twice as slow in its runtime; FireRedASR2 (int8), Paraformer and SenseVoice are less accurate; Whisper large-v3-turbo is the only one that writes "M1" and "36G" by itself and the least accurate. Qwen3-ASR 0.6B stays.
- None of them can be told to write numbers in digits; Qwen ignores such an instruction in its context.
- Telling the model which Latin terms the system recognizer heard changed 3 of 54 sentences, one for the better, one for the worse.
- The text in front of the caret as the model's context: it copied the spacing style and nothing else.

Not done, and said plainly:

- Learning names and terms from the corrections you make after a dictation (Doubao learns from them). It means watching what is typed after a dictation; that needs a decision first.
- A text model for a last pass (fillers, changes of mind, lists, paragraphs) — what Doubao's "smart organize" and Typeless do. Offered and declined for now; "AI proofreading" with an endpoint of your own remains.
- Noise suppression and telling speakers apart.

Verified on the development Mac: all tests, the three self-tests, and the measurements above. Not yet on device: 0.6.1 and 0.6.2.

## 0.6.1 (local testing)

Found on device within minutes of installing 0.6.0, from the diagnostics and from what was said.

- A dictation is no longer refused while a recognizer is being downloaded, verified or loaded. Two presses were answered with "Models for the current language are being prepared" while Qwen3-ASR was being loaded right after its download, although the system recognizer was ready. What is ready now stays usable: the words appear at once, and until the model is loaded the system recognizer's text is written. The model is loaded in the background.
- Numbers are written the way they are written. The downloaded models spell them out: "M一芯片", "iPhone十五", "三十六G内存" — the preview said "M1" and the release changed it. Where the system recognizer and the model heard the same number, the final text takes the system's way of writing it ("M1芯片", "iPhone 15 Pro", "36G内存", "3.5", "2026年10月2号"). A number the two disagree about stays as the model heard it. (The measurement in 0.6.0 left out sentences with digits, which is how this was missed.)
- The screen-translation shortcut no longer makes the Mac beep. Only the first press of ⌥T was taken; held a moment longer, the key repeats, and every repeat went on to the application in front, which beeped (or typed the letter). The repeats and the release of the key are now part of the chord, in the main program and in the input method. The shortcut can be changed in Settings → Screen Translation, as before.
- The diagnostics say who wrote each final text (`final-text model …` or `system:model-too-slow` / `system:model-failed`).

On device with 0.6.0 (two dictations of about three seconds, Qwen3-ASR selected): first character 0.54 s and 0.70 s after the voice started; text 0.25 s and 0.31 s after the release.

Not measured: a Mac slower than the development one (M3 Max). The system recognizer's part is the same on every supported Mac; the model's second pass runs on the GPU and will take longer on an M1 — if it exceeds 2.5 s plus a fifth of the recording, the system recognizer's text is written instead.

## 0.6.0 (local testing)

"Doubao feels more live, faster and more accurate — find out how, and get there." How such a product gets there (`docs/SPEECH_PIPELINE.md`): recognition runs in the cloud, the streaming result is corrected in further passes, and a "typewriter" lets new characters out one at a time. Saylane now does the same things on the Mac.

### Speaking

- The words on screen follow the voice. They changed about once a second, three to six characters at a time: that is how often Apple's accurate recognizer answers, whatever it is fed. Its dictation model answers about every 0.26 s, and is now the preview for the whole utterance, not just its first words (measured on real speech replayed in real time: a screen update every 257 ms, before every 899 ms).
- New characters are typed out a few at a time instead of landing in a clump; a correction of characters that are already shown replaces them in place.
- Two passes. With a downloaded recognizer selected, the system recognizer still shows the words while you speak, and the model writes the final text when the key is released. On 150 recordings of real Mandarin speech (FLEURS test set) the system recognizer got 5.2% of the characters wrong, SenseVoiceSmall 3.7%, Qwen3-ASR 0.6B 2.0%; whole sentences right: 60, 73 and 96 of 150. The final text is there 0.34 s after the release (median, sentences of about ten seconds; nine in ten within 0.56 s). If the model fails or takes too long, what the system recognizer heard is written.
- No more 30-second limit with a downloaded recognizer. A long dictation is handed to the model in stretches that end where a sentence ends, while you are still speaking; only the last stretch is left at the release (50 s of continuous speech: three stretches, text 0.42 s after the release).
- The recognizer no longer shows or writes a space in front of Chinese punctuation ("欢迎 ，并与").

### Settings and menu, gone through one by one

- Voice Input has a "Recognizer" row that says which one is in use and takes you to the list.
- "Local Models" is now "Models": the three recognizers that were measured, each with its size and error figure; the pinyin sentence model, which was only on the Keyboard page; then the status of the current languages. A recognizer is selected as soon as its download finishes. Qwen 4-bit and Fun-ASR-Nano were never measured and are listed only for those who already have them.
- "I speak / Write" are "First language / Second language": they are the pair, and "Current" says which of the four ways to combine them is in use.
- Removed "Recognize only, do not translate". It said what the direction already says; whoever had it on keeps writing the language that is spoken.
- Removed the "Speech Recognition" permission row. The on-device recognizers never ask for it.
- Removed the "Models for the current language — Download" row; a Download button appears in the status row that needs it.
- The input-method menu lists the four modes with a tick on the current one, instead of a greyed-out title and "Switch translation direction". "Open the Rime user dictionary folder" moved to Keyboard Input ("Learned words — Show in Finder").
- Not exposed, on purpose: the languages of screen translation (changed with D on the pinned translation).

### Engineering

- `Saylane --asr-bench list.txt out.jsonl --speech-model … [--realtime] [--solo]` replays recordings through a recognizer and records the final text and the moment of every preview.
- Dictation metrics record when the voice starts (`voiceStarted`), so "voice to first character" can be read from a real session.
- The bridge protocol is version 3 (menu modes).

Not done, and said plainly:

- Accuracy is still behind a cloud model, mostly on names and terms. A larger local model (Qwen3-ASR 1.7B) is not integrated and was not measured. A cloud recognizer was offered and declined for now.
- The preview comes from the dictation model, which makes more mistakes than the final text; a few characters change when the final text arrives.
- English and the other languages were not measured on real speech.
- The comparison with Doubao is of methods, not of numbers on the same recordings.

Verified on the development Mac: all tests, the three self-tests of the built programs, and the measurements above. Not yet seen on device: everything in this release.

## 0.5.0 (local testing)

A review of the installed 0.4.1 against Doubao produced eight items. This release does six of them and part of a seventh; what is left is listed at the end.

### Speaking

- The first words of the preview arrive in about half the time. Apple's `SpeechTranscriber` gives its first result roughly 1.05 s after you start to speak; `DictationTranscriber` gives one after about 0.54 s (measured on the same recordings, fed in real time). Both now listen to the same audio: the fast one fills the preview until the accurate one has spoken, and the final text always comes from the accurate one.
- A new installation writes what you say: Chinese in, Chinese out. Translation is one choice away (Settings, or a double tap of right ⌘). Existing installations keep the direction they had.
- A short sound when listening starts and another when it stops (Settings → Voice Input, on by default).
- The microphone can be chosen (Settings → Voice Input). If the chosen one is unplugged, the system's default is used.
- Two choices for how the text is written (Settings → Text Correction, both off by default): no full stop at the end, and a space between Chinese and Latin letters or digits.

### Typing

- Page keys are choices: `- =` and Tab (on), `, .` and `[ ]` (off). Page Up / Page Down always work.
- `;` and `'` can pick the second and third candidate (off by default).
- Western punctuation while typing Chinese (off by default).
- An optional language model for whole sentences (Settings → Keyboard Input → Sentence language model). It is the Wanxiang LTS grammar, 409 MB, CC BY 4.0, downloaded from its GitHub release, checked against a pinned SHA-256 and kept on this Mac; the input method itself never goes online. On 60 everyday sentences the first candidate was the whole sentence 35 times without it and 44 times with it. Without the download nothing changes. The plugin that reads it (librime's octagram, BSD-3) ships in the package.

### Program

- "Quit Saylane" at the bottom of the settings sidebar. Typing keeps working; the input method starts the main program again when it is needed.

### Corrections

- The READMEs said the terminology glossary is on by default. It is off.

Not done from the list, and said plainly:

- A recorder for an arbitrary talk-key combination. The key is still chosen from a list.
- Shuangpin (小鹤双拼).
- ⌘Z to take back a proofreading, and learning from a correction made by hand.
- Automatic updates and a signed, notarized installer. Deferred earlier; they need credentials that are not on the development Mac.
- Accuracy with the optional model is better than before and still behind Doubao's, which uses a far larger model in the cloud.

Verified on the development Mac: all tests and the three self-tests of the built programs. Not yet confirmed on device: the cue sounds, the microphone choice, the faster preview with a real voice, and the language-model download from Settings.

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
