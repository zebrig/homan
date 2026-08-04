#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCALVQE_REPO="${LOCALVQE_REPO:-/tmp/LocalVQE}"
LOCALVQE_REF="${LOCALVQE_REF:-f53063c9eb2a85f96479867d1dd911dc3bf6319b}"
BUILD_DIR="${LOCALVQE_BUILD_DIR:-$LOCALVQE_REPO/ggml/build-muesli-gtcrn}"
OUT_DIR="${MUESLI_LOCALVQE_LIB_DIR:-$ROOT/native/MuesliNative/LocalVQE/lib}"

for tool in cmake git install_name_tool otool; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool for LocalVQE build: $tool" >&2
    exit 1
  fi
done

if [[ ! -e "$LOCALVQE_REPO/.git" ]]; then
  git clone https://github.com/localai-org/LocalVQE.git "$LOCALVQE_REPO"
fi
git -C "$LOCALVQE_REPO" remote set-url origin https://github.com/localai-org/LocalVQE.git
if git -C "$LOCALVQE_REPO" cat-file -e "$LOCALVQE_REF^{commit}" 2>/dev/null; then
  git -C "$LOCALVQE_REPO" checkout --detach "$LOCALVQE_REF"
else
  git -C "$LOCALVQE_REPO" fetch --depth 1 origin "$LOCALVQE_REF"
  git -C "$LOCALVQE_REPO" checkout --detach FETCH_HEAD
fi

git -C "$LOCALVQE_REPO" submodule update --init --depth 1 ggml/vendor/ggml

CMAKE_ARGS=(
  -S "$LOCALVQE_REPO/ggml"
  -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
  -DLOCALVQE_BUILD_SHARED=ON
  -DLOCALVQE_VULKAN=OFF
  -DLOCALVQE_CUDA=OFF
  -DGGML_METAL=OFF
)
if [[ "$(uname -m)" == "arm64" ]]; then
  CMAKE_ARGS+=("-DGGML_CPU_ARM_ARCH=armv9.2-a+dotprod+i8mm+nosve+sme")
fi
cmake "${CMAKE_ARGS[@]}"

BUILD_JOBS="${LOCALVQE_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
cmake --build "$BUILD_DIR" --target localvqe_shared -j"$BUILD_JOBS"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/liblocalvqe*.dylib "$OUT_DIR"/libggml*.dylib "$OUT_DIR"/libggml*.so
find "$BUILD_DIR" -maxdepth 4 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) -type f | while read -r dylib; do
  cp "$dylib" "$OUT_DIR/$(basename "$dylib")"
done

if [[ -f "$OUT_DIR/liblocalvqe.0.1.0.dylib" && ! -f "$OUT_DIR/liblocalvqe.dylib" ]]; then
  ln -s "liblocalvqe.0.1.0.dylib" "$OUT_DIR/liblocalvqe.dylib"
fi
if [[ -f "$OUT_DIR/liblocalvqe.0.1.0.dylib" && ! -f "$OUT_DIR/liblocalvqe.0.dylib" ]]; then
  ln -s "liblocalvqe.0.1.0.dylib" "$OUT_DIR/liblocalvqe.0.dylib"
fi

for dylib in "$OUT_DIR"/liblocalvqe*.dylib "$OUT_DIR"/libggml*.dylib "$OUT_DIR"/libggml*.so; do
  [[ -f "$dylib" ]] || continue
  if otool -l "$dylib" | grep -Fq "$BUILD_DIR/bin"; then
    install_name_tool -delete_rpath "$BUILD_DIR/bin" "$dylib" 2>/dev/null || true
  fi
  if ! otool -l "$dylib" | grep -Fq "@loader_path"; then
    install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
  fi
done

required_runtime_files=(
  "liblocalvqe.dylib"
  "liblocalvqe.0.dylib"
  "liblocalvqe.0.1.0.dylib"
)
for file_name in "${required_runtime_files[@]}"; do
  if [[ ! -e "$OUT_DIR/$file_name" ]]; then
    echo "LocalVQE build did not produce required runtime file: $OUT_DIR/$file_name" >&2
    exit 1
  fi
done
printf '%s\n' "$LOCALVQE_REF" > "$OUT_DIR/.muesli-localvqe-runtime-ref"

echo "LocalVQE runtime $LOCALVQE_REF copied to $OUT_DIR"
