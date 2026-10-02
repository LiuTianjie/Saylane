#!/bin/bash
# Build the evaluation tools into build/screen-eval/. Usage: build.sh [snapshot|baseline|v2]
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/screen-eval/pages build/screen-eval/out
PRODUCTION="Sources/Models/AppLanguage.swift Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift
  Sources/Screen/ScreenLayout.swift Sources/Screen/ScreenFontWeightService.swift Sources/Screen/ScreenOCRService.swift
  Sources/Screen/ScreenPinRenderer.swift Sources/Services/TranslationEngine.swift"
FLAGS="-O -swift-version 6 -strict-concurrency=complete -parse-as-library -framework AppKit -framework Vision -framework CoreImage -framework Translation"
what="${1:-all}"
if [[ $what == snapshot || $what == all ]]; then
  swiftc -O -parse-as-library -o build/screen-eval/snapshot scripts/screen-eval/snapshot.swift
fi
if [[ $what == baseline || $what == all ]]; then
  swiftc $FLAGS $PRODUCTION scripts/screen-eval/baseline.swift -o build/screen-eval/baseline
fi
if [[ $what == v2 || $what == all ]]; then
  swiftc $FLAGS $PRODUCTION scripts/screen-eval/v2/*.swift -o build/screen-eval/v2
fi
