#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 3 ]]; then
  echo 'usage: scripts/test-screen-scenarios.sh paper.png x.png chat.png' >&2
  exit 2
fi
mkdir -p build/tests/scenarios
swiftc -framework AppKit -framework Vision -framework CoreImage -framework Translation \
  Sources/Models/AppLanguage.swift Sources/Models/SpeechModel.swift Sources/Models/ScreenTranslate.swift \
  Sources/Services/ScreenFontWeightService.swift Sources/Services/ScreenOCRService.swift Sources/Services/ScreenPinRenderer.swift \
  Sources/Services/TranslationEngine.swift Tests/ScreenTranslationPreview.swift \
  -o build/tests/scenarios/preview
failed=0
labels=(paper x chat)
index=0
for source in "$@"; do
  directory="build/tests/scenarios/${labels[$index]}"
  mkdir -p "$directory"
  # Run sequentially: no competing translation sessions in timing samples.
  if ! build/tests/scenarios/preview "$source" "$directory" --strict > "$directory/run.log" 2>&1; then
    failed=1
  fi
  cat "$directory/run.log"
  index=$((index + 1))
done
exit "$failed"
