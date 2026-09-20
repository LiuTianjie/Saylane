#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/Models/AppLanguage.swift Sources/Models/SpeechModel.swift Sources/Models/SpeechEngineError.swift \
  Sources/Models/SessionState.swift Sources/Models/SpeechHypothesis.swift Sources/Models/SpeechSessionMetrics.swift \
  Sources/Services/ASRModelInstaller.swift Sources/Services/BufferConverter.swift Sources/Services/AudioLevel.swift \
  Sources/Services/QwenAudioBuffer.swift Sources/Services/LocalSpeechRuntime.swift \
  Sources/Services/SessionCoordinator.swift Sources/Services/QwenSpeechEngine.swift \
  Tests/LocalSpeechEngineTests.swift -o build/tests/local-speech
build/tests/local-speech
