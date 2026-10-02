#!/bin/bash
# Run a tool over every sample. Usage: run.sh <baseline|v2> <out-dir> [extra args]
set -euo pipefail
cd "$(dirname "$0")/../.."
tool="$1"; out="$2"; shift 2
mkdir -p "$out"
for image in build/screen-eval/pages/*.png; do
  name="$(basename "$image" .png)"
  scale="${name##*@}"; scale="${scale%x}"
  if [[ $name == *-en@* ]]; then source=en; target=zh-Hans; else source=zh-Hans; target=en; fi
  "build/screen-eval/$tool" "$image" "$scale" "$source" "$target" "$out/$name" "$@" | tail -1
done
