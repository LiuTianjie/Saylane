#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
mkdir -p build/tests
# Match the app's language/concurrency mode; Swift 5 tests miss the runtime trap.
sources=(
  Sources/Models/SessionState.swift Sources/Models/SpeechHypothesis.swift
  Sources/Models/SpeechSessionMetrics.swift Sources/Models/SpeechEngineError.swift
  Sources/Services/AudioLevel.swift Sources/Services/BufferConverter.swift
  Sources/Voice/VoicePolicy.swift Sources/Voice/SessionCoordinator.swift
  Sources/Services/AudioInputDevices.swift Sources/Services/AudioCaptureService.swift Tests/AudioCaptureTests.swift
)
for mode in debug release; do
  flags=(-Onone)
  if [[ "$mode" == release ]]; then flags=(-O); fi
  swiftc -swift-version 6 -strict-concurrency=complete "${flags[@]}" \
    "${sources[@]}" -o "build/tests/audio-capture-$mode"
  "build/tests/audio-capture-$mode"
done
