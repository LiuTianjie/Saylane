#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare-rime.py
mkdir -p build/tests
clang -c Sources/IME/Rime/SaylaneRime.c -I Vendor/Rime/Runtime/include -o build/tests/rime-bridge.o
swiftc -import-objc-header Sources/IME/Rime/SaylaneRime.h \
  Sources/IME/Pinyin/PinyinCandidate.swift Sources/IME/Pinyin/PinyinKeyEvent.swift \
  Sources/IME/Rime/RimeRuntime.swift Sources/IME/Rime/RimePinyinSession.swift \
  Tests/RimeTests.swift build/tests/rime-bridge.o \
  -L Vendor/Rime/Runtime/lib -lrime -o build/tests/rime
DYLD_LIBRARY_PATH="$PWD/Vendor/Rime/Runtime/lib" build/tests/rime "$PWD/Vendor/Rime/Rime"

USER_DATA="$(mktemp -d /tmp/saylane-rime-persistence.XXXXXX)"
trap 'rm -rf "$USER_DATA"' EXIT
DYLD_LIBRARY_PATH="$PWD/Vendor/Rime/Runtime/lib" build/tests/rime "$PWD/Vendor/Rime/Rime" --learn "$USER_DATA"
DYLD_LIBRARY_PATH="$PWD/Vendor/Rime/Runtime/lib" build/tests/rime "$PWD/Vendor/Rime/Rime" --verify-learning "$USER_DATA"
