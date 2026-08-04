#!/usr/bin/env bash
set -euo pipefail

if command -v homan-cli >/dev/null 2>&1; then
  command -v homan-cli
  exit 0
fi

if [[ -x "/Applications/Muesli.app/Contents/MacOS/homan-cli" ]]; then
  echo "/Applications/Muesli.app/Contents/MacOS/homan-cli"
  exit 0
fi

if [[ -x "native/MuesliNative/.build/debug/homan-cli" ]]; then
  echo "$(pwd)/native/MuesliNative/.build/debug/homan-cli"
  exit 0
fi

if [[ -x "native/MuesliNative/.build/release/homan-cli" ]]; then
  echo "$(pwd)/native/MuesliNative/.build/release/homan-cli"
  exit 0
fi

exit 1
