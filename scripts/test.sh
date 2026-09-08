#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/Services/BufferConverter.swift Tests/PCMCopyTests.swift -o build/tests/pcm
build/tests/pcm
swiftc Sources/Models/PushToTalkHotkey.swift Sources/Services/PushToTalkHandler.swift Tests/HotkeyTests.swift -o build/tests/hotkey
build/tests/hotkey
swiftc Sources/Models/PushToTalkHotkey.swift Sources/Services/PushToTalkHandler.swift Sources/Services/InputShortcutHandler.swift Sources/Services/GlobalHotkeyRouter.swift Tests/GlobalHotkeyTests.swift -o build/tests/global-hotkey
build/tests/global-hotkey
swiftc Sources/Models/PushToTalkHotkey.swift Sources/Services/PushToTalkHandler.swift Sources/Services/InputShortcutHandler.swift Tests/InputShortcutTests.swift -o build/tests/gestures
build/tests/gestures
swiftc Sources/Models/SessionState.swift Sources/Services/AudioLevel.swift Sources/Services/SessionCoordinator.swift Tests/SessionCoordinatorTests.swift -o build/tests/session
build/tests/session
swiftc Sources/Services/FinalPolishService.swift Tests/FinalPolishTests.swift -o build/tests/polish
build/tests/polish
bash -n scripts/pkg/preinstall scripts/pkg/postinstall
swiftc -parse-as-library Tests/InputIconTests.swift -o build/tests/input-icon
build/tests/input-icon
swiftc Sources/Models/SessionState.swift Sources/Services/OverlayController.swift Sources/Views/OverlayView.swift Tests/OverlayNoticeTests.swift -o build/tests/overlay-notice
build/tests/overlay-notice
swiftc Sources/Models/SetupReadiness.swift Tests/SetupReadinessTests.swift -o build/tests/setup-readiness
build/tests/setup-readiness
swiftc Sources/Models/AppLanguage.swift Tests/TranslationDirectionTests.swift -o build/tests/direction
build/tests/direction
swiftc Sources/IME/Pinyin/PinyinSyllable.swift Sources/IME/Pinyin/PinyinLexicon.swift Sources/IME/Pinyin/PinyinLanguageModel.swift Sources/IME/Pinyin/PinyinDecoder.swift Sources/IME/Pinyin/PinyinSession.swift Tests/PinyinTests.swift -o build/tests/pinyin
build/tests/pinyin
swiftc Sources/Models/AppLanguage.swift Sources/Models/SpeechModel.swift Sources/Models/SpeechEngineError.swift Sources/Services/ASRModelInstaller.swift Sources/Services/BufferConverter.swift Sources/Services/QwenAudioBuffer.swift Tests/ASRModelTests.swift -o build/tests/asr-models
build/tests/asr-models
swiftc Sources/Models/AppLanguage.swift Sources/Models/SpeechModel.swift Sources/Services/LocalSpeechRuntime.swift Tests/LocalSpeechRuntimeTests.swift -o build/tests/asr-lifetime
build/tests/asr-lifetime
swiftc Sources/Models/AppLanguage.swift Sources/Models/SpeechModel.swift Sources/Services/LocalSpeechRuntime.swift Sources/Services/QwenWorkerModel.swift Tests/QwenWorkerIOTests.swift -o build/tests/asr-worker-io
build/tests/asr-worker-io
