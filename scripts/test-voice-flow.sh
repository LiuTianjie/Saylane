#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
mkdir -p build/tests
shared=(
  Sources/Models/SessionState.swift Sources/Models/SpeechHypothesis.swift
  Sources/Models/SpeechSessionMetrics.swift Sources/Models/SpeechEngineError.swift
  Sources/Services/AudioLevel.swift Sources/Services/BufferConverter.swift
  Sources/Voice/VoicePolicy.swift Sources/Voice/SessionCoordinator.swift
  Sources/Services/AudioCaptureService.swift Sources/Voice/PrerollCapture.swift
)
swiftc -swift-version 6 -strict-concurrency=complete "${shared[@]}" \
  Tests/VoiceLifecycleRegressionTests.swift -o build/tests/voice-lifecycle
build/tests/voice-lifecycle
swiftc -swift-version 6 -strict-concurrency=complete "${shared[@]}" \
  Sources/Models/AppLanguage.swift Sources/Models/PushToTalkHotkey.swift Sources/Models/SpeechModel.swift \
  Sources/Models/SetupReadiness.swift Sources/Models/SetupFlow.swift Sources/Screen/ScreenLayout.swift \
  Sources/Core/AppDirectories.swift Sources/Core/Preferences.swift Sources/Core/Readiness.swift Sources/Core/UserNotice.swift \
  Sources/Input/InputEvent.swift Sources/Input/InputEventRouter.swift Sources/Input/GestureArbiter.swift \
  Sources/Input/GlobalHotkeyMonitor.swift Sources/Input/VoiceGesture.swift \
  Sources/Input/ScreenHoldHandler.swift Sources/Input/ShortcutValidator.swift \
  Sources/Voice/OverlayController.swift Sources/Views/OverlayView.swift Sources/Voice/AccessibilityInserter.swift \
  Sources/Voice/VoiceInputEnvironment.swift Sources/Voice/VoiceTarget.swift Sources/Voice/VoiceSessionController.swift \
  Sources/Support/InputDiagnostics.swift \
  Tests/VoiceSessionControllerTests.swift -o build/tests/voice-controller
build/tests/voice-controller
