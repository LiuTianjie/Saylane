#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/Models/AppLanguage.swift Sources/Models/SpeechModel.swift Sources/Models/SpeechEngineError.swift Sources/Services/ASRModelInstaller.swift Sources/Services/BufferConverter.swift Sources/Services/QwenAudioBuffer.swift Sources/Services/LocalSpeechRuntime.swift Sources/Services/NativeASRModel.swift Tests/NativeASRTests.swift -o build/tests/native-asr
build/tests/native-asr
