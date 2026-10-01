#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai

swiftc() {
  command swiftc -swift-version 6 -strict-concurrency=complete "$@"
}

cd "$(dirname "$0")/.."
mkdir -p build/tests
bash scripts/test-audio-capture.sh
bash scripts/test-voice-flow.sh
python3 Tests/BrandingTests.py
python3 Tests/InstallerLifecycleTests.py
python3 Tests/UIStateContractTests.py
bash scripts/test-app-directories.sh
python3 Tests/ASRBenchmarkTests.py
swiftc Sources/Services/BufferConverter.swift Tests/PCMCopyTests.swift -o build/tests/pcm
build/tests/pcm
swiftc Sources/Services/AudioLevel.swift Tests/AudioSignalTests.swift -o build/tests/audio-signal
build/tests/audio-signal
swiftc Sources/Input/VoiceGesture.swift Tests/VoiceGestureTests.swift -o build/tests/voice-gesture
build/tests/voice-gesture
swiftc Sources/Shared/BridgePort.swift Tests/BridgePortTests.swift -o build/tests/bridge-port
build/tests/bridge-port
swiftc Sources/Models/SessionState.swift Sources/Models/SpeechHypothesis.swift Sources/Models/SpeechSessionMetrics.swift Sources/Models/SpeechEngineError.swift Sources/Services/AudioLevel.swift Sources/Voice/VoicePolicy.swift Sources/Voice/SessionCoordinator.swift Tests/SessionCoordinatorTests.swift -o build/tests/session
build/tests/session
swiftc Sources/Services/FinalPolishService.swift Tests/FinalPolishTests.swift -o build/tests/polish
build/tests/polish
swiftc Sources/Services/DictationCleanup.swift Tests/DictationCleanupTests.swift -o build/tests/dictation-cleanup
build/tests/dictation-cleanup
swiftc Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift Sources/Services/DictationVocabulary.swift Sources/Services/DictationGlossary.swift Tests/DictationVocabularyTests.swift -o build/tests/dictation-vocabulary
build/tests/dictation-vocabulary
swiftc Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift Sources/Services/DictationVocabulary.swift Sources/Services/DictationGlossary.swift Sources/Services/DictationGlossaryRemote.swift Tests/DictationGlossaryRemoteTests.swift -o build/tests/dictation-glossary-remote
build/tests/dictation-glossary-remote
bash -n scripts/pkg/preinstall scripts/pkg/postinstall
swiftc -parse-as-library Tests/InputIconTests.swift -o build/tests/input-icon
build/tests/input-icon
swiftc Sources/Models/SessionState.swift Sources/Voice/OverlayController.swift Sources/Views/OverlayView.swift Tests/OverlayNoticeTests.swift -o build/tests/overlay-notice
build/tests/overlay-notice
swiftc Sources/Models/SetupReadiness.swift Tests/SetupReadinessTests.swift -o build/tests/setup-readiness
build/tests/setup-readiness
swiftc Sources/Models/SetupFlow.swift Tests/SetupFlowTests.swift -o build/tests/setup-flow
build/tests/setup-flow
swiftc Sources/Models/AppLanguage.swift Tests/TranslationDirectionTests.swift -o build/tests/direction
build/tests/direction
swiftc -framework AppKit Sources/Models/AppLanguage.swift Sources/Screen/ScreenLayout.swift Tests/ScreenTranslateTests.swift -o build/tests/screen-translate
swiftc -framework AppKit -framework Vision Sources/Models/AppLanguage.swift Sources/Screen/ScreenLayout.swift Sources/Screen/ScreenOCRService.swift Tests/ScreenFontCalibrationTests.swift -o build/tests/screen-font
build/tests/screen-font
build/tests/screen-translate
swiftc -framework AppKit Sources/Models/PushToTalkHotkey.swift Sources/Input/ScreenHoldHandler.swift Tests/ScreenHoldTests.swift -o build/tests/screen-hold
build/tests/screen-hold
INPUT_SOURCES="Sources/Models/AppLanguage.swift Sources/Screen/ScreenLayout.swift Sources/Models/PushToTalkHotkey.swift Sources/Input/VoiceGesture.swift Sources/Input/ScreenHoldHandler.swift Sources/Input/InputEvent.swift Sources/Input/GestureArbiter.swift Sources/Input/ShortcutValidator.swift"
swiftc -framework AppKit $INPUT_SOURCES Tests/GestureArbiterTests.swift -o build/tests/gesture-arbiter
build/tests/gesture-arbiter
swiftc -framework AppKit $INPUT_SOURCES Tests/ShortcutValidatorTests.swift -o build/tests/shortcut-validator
build/tests/shortcut-validator
swiftc -framework AppKit $INPUT_SOURCES Sources/Input/GlobalHotkeyMonitor.swift Sources/Input/InputEventRouter.swift Tests/InputEventRouterTests.swift -o build/tests/input-router
build/tests/input-router
swiftc -parse-as-library -framework AppKit -framework Carbon \
  Sources/IME/Pinyin/PinyinHandling.swift Sources/IME/Pinyin/PinyinEngine.swift Tests/PinyinEngineLeaseTests.swift -o build/tests/pinyin-lease
build/tests/pinyin-lease
swiftc -framework AppKit -framework InputMethodKit Sources/IME/IMEManager.swift Sources/IME/CurrentInputSource.swift \
  Sources/IME/Pinyin/PinyinKeyEvent.swift Tests/IMEManagerTests.swift -o build/tests/ime-manager
build/tests/ime-manager
swiftc Sources/IME/InputDeferralDeadline.swift Tests/InputDeferralDeadlineTests.swift -o build/tests/input-deferral
build/tests/input-deferral
swiftc -framework AppKit -framework InputMethodKit Sources/Shared/BridgeMessages.swift Sources/Shared/TestHome.swift \
  Sources/IME/InputMethodCore.swift Sources/IME/IMEManager.swift Sources/IME/CurrentInputSource.swift \
  Sources/IME/InputDeferralDeadline.swift Sources/IME/Pinyin/PinyinHandling.swift Sources/IME/Pinyin/PinyinKeyEvent.swift \
  Sources/Models/PushToTalkHotkey.swift Tests/InputMethodCoreTests.swift -o build/tests/ime-core
build/tests/ime-core
swiftc -framework AppKit Sources/Models/AppLanguage.swift Sources/Screen/ScreenLayout.swift Sources/Models/PushToTalkHotkey.swift Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift Sources/Core/Preferences.swift Sources/Core/PreferencesStore.swift Tests/PreferencesStoreTests.swift -o build/tests/preferences
build/tests/preferences
swiftc Sources/Models/SetupReadiness.swift Sources/Models/SetupFlow.swift Sources/Core/UserNotice.swift Sources/Core/Readiness.swift Tests/ReadinessTests.swift -o build/tests/readiness
build/tests/readiness
swiftc Sources/Models/SessionState.swift Sources/Models/SpeechHypothesis.swift Sources/Models/SpeechSessionMetrics.swift Sources/Services/AudioLevel.swift Sources/Services/BufferConverter.swift Sources/Models/SpeechEngineError.swift Sources/Voice/VoicePolicy.swift Sources/Voice/SessionCoordinator.swift Sources/Services/AudioCaptureService.swift Sources/Voice/PrerollCapture.swift Tests/PrerollCaptureTests.swift -o build/tests/preroll
build/tests/preroll
swiftc -framework AppKit -framework CoreImage Sources/Models/AppLanguage.swift Sources/Screen/ScreenLayout.swift Sources/Screen/ScreenPinRenderer.swift Tests/ScreenPinRendererTests.swift -o build/tests/screen-pin
build/tests/screen-pin
mkdir -p build/tests/ASR
cp Sources/Resources/ASR/*.json build/tests/ASR/
swiftc Sources/Models/AppLanguage.swift Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift Sources/Models/SpeechEngineError.swift Sources/Services/ASRModelInstaller.swift Sources/Services/ASRModelStore.swift Sources/Services/BufferConverter.swift Sources/Services/QwenAudioBuffer.swift Tests/ASRModelTests.swift -o build/tests/asr-models
build/tests/asr-models
swiftc Sources/Models/AppLanguage.swift Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift Sources/Services/LocalSpeechRuntime.swift Tests/LocalSpeechRuntimeTests.swift -o build/tests/asr-lifetime
build/tests/asr-lifetime
swiftc Sources/Models/AppLanguage.swift Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift Sources/Services/LocalSpeechRuntime.swift Sources/Services/QwenWorkerModel.swift Tests/QwenWorkerIOTests.swift -o build/tests/asr-worker-io
build/tests/asr-worker-io
bash scripts/test-native-asr.sh
bash scripts/test-local-speech.sh

scripts/test-rime.sh

scripts/test-rime-updates.sh
