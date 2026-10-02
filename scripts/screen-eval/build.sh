#!/bin/bash
# Build the evaluation tools into build/screen-eval/. Usage: build.sh [snapshot|v2]
# (`baseline`, the pipeline shipped until 0.6, was built from sources that are gone: its scores are in docs/SCREEN_TRANSLATE_V2.md §3.)
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/screen-eval/pages build/screen-eval/out
PRODUCTION="Sources/Models/AppLanguage.swift Sources/Core/AppDirectories.swift Sources/Models/SpeechModel.swift
  Sources/Screen/ScreenLayout.swift Sources/Services/TranslationEngine.swift"
FLAGS="-O -swift-version 6 -strict-concurrency=complete -parse-as-library -framework AppKit -framework Vision -framework CoreImage -framework Translation"
what="${1:-all}"
if [[ $what == snapshot || $what == all ]]; then
  swiftc -O -parse-as-library -o build/screen-eval/snapshot scripts/screen-eval/snapshot.swift
fi
if [[ $what == v2 || $what == all ]]; then
  swiftc $FLAGS $PRODUCTION Sources/Screen/Pipeline/*.swift scripts/screen-eval/v2/*.swift -o build/screen-eval/v2
fi
