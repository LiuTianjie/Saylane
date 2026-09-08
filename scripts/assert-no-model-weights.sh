#!/bin/bash
set -euo pipefail
APP="${1:?usage: assert-no-model-weights.sh APP_PATH}"
[[ -d "$APP/Contents" ]] || { echo "Not an app bundle: $APP" >&2; exit 1; }
FOUND="$(find "$APP" -type f \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.onnx' -o -name 'pytorch_model*.bin' \) -print -quit)"
[[ -z "$FOUND" ]] || { echo "Refusing to package optional model weights: $FOUND" >&2; exit 1; }
echo 'PASS: app bundle contains no optional ASR model weights'
