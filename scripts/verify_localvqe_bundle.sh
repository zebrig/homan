#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"
EXPECTED_GTCRN_MODEL_SHA256="0e0c82a8e9703e818b64dedd0fc306394cf5bbb59fcec1ccca82099d352d0c26"
EXPECTED_V12_MODEL_SHA256="4856ecf5f522b23fb2bc5caeac81f323c0ef1c4c156a9c7d40a6adbe092ba9ce"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH/Contents" ]]; then
  echo "Usage: $0 /path/to/Muesli.app" >&2
  exit 2
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
GTCRN_MODEL_PATH="$APP_PATH/Contents/Resources/Models/localvqe/localvqe-pi-v1-49k-f32.gguf"
V12_MODEL_PATH="$APP_PATH/Contents/Resources/Models/localvqe/localvqe-v1.2-1.3M-f32.gguf"
LOCALVQE_LIBRARY="$FRAMEWORKS_DIR/liblocalvqe.dylib"

required_runtime_files=(
  "liblocalvqe.dylib"
  "liblocalvqe.0.dylib"
  "liblocalvqe.0.1.0.dylib"
)
for file_name in "${required_runtime_files[@]}"; do
  if [[ ! -e "$FRAMEWORKS_DIR/$file_name" ]]; then
    echo "Missing bundled LocalVQE runtime file: $FRAMEWORKS_DIR/$file_name" >&2
    exit 1
  fi
done

verify_model() {
  local model_path="$1"
  local expected_sha256="$2"
  if [[ ! -f "$model_path" ]]; then
    echo "Missing bundled LocalVQE model: $model_path" >&2
    exit 1
  fi
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$model_path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "Bundled LocalVQE model checksum mismatch: $model_path" >&2
    echo "Expected: $expected_sha256" >&2
    echo "Actual:   $actual_sha256" >&2
    exit 1
  fi
}
verify_model "$GTCRN_MODEL_PATH" "$EXPECTED_GTCRN_MODEL_SHA256"
verify_model "$V12_MODEL_PATH" "$EXPECTED_V12_MODEL_SHA256"

while IFS= read -r library; do
  if otool -l "$library" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -q '^/'; then
    echo "Bundled library contains an absolute build rpath: $library" >&2
    exit 1
  fi
  while IFS= read -r dependency; do
    dependency_name="${dependency#@rpath/}"
    if [[ ! -e "$FRAMEWORKS_DIR/$dependency_name" ]]; then
      echo "Missing @rpath dependency for $(basename "$library"): $dependency_name" >&2
      exit 1
    fi
  done < <(otool -L "$library" | awk '$1 ~ /^@rpath\/lib(ggml|localvqe)/ { print $1 }')
done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) -type f)

smoke_binary="$(mktemp "${TMPDIR:-/tmp}/muesli-localvqe-smoke.XXXXXX")"
cleanup() {
  rm -f "$smoke_binary"
}
trap cleanup EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror "$ROOT/scripts/localvqe_runtime_smoke.c" -o "$smoke_binary"
"$smoke_binary" "$LOCALVQE_LIBRARY" "$GTCRN_MODEL_PATH"
"$smoke_binary" "$LOCALVQE_LIBRARY" "$V12_MODEL_PATH"

echo "Verified bundled LocalVQE runtime and both models in $APP_PATH"
