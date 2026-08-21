#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="${1:-debug}"
INSTALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/muesli-packaging-test.XXXXXX")"
APP_BUNDLE_NAME="MuesliPackagingTest.app"
APP_PATH="$INSTALL_ROOT/$APP_BUNDLE_NAME"
APP_BIN="$APP_PATH/Contents/MacOS/Homan"
CLI_BIN="$APP_PATH/Contents/MacOS/homan-cli"
LOCALVQE_LIBRARY="$APP_PATH/Contents/Frameworks/liblocalvqe.dylib"
LOCALVQE_GTCRN_MODEL="$APP_PATH/Contents/Resources/Models/localvqe/localvqe-pi-v1-49k-f32.gguf"
LOCALVQE_V12_MODEL="$APP_PATH/Contents/Resources/Models/localvqe/localvqe-v1.2-1.3M-f32.gguf"
SPEC_OUTPUT="$INSTALL_ROOT/homan-cli-spec.json"
TRANSCRIBE_HELP_OUTPUT="$INSTALL_ROOT/homan-cli-transcribe-help.txt"
ENTITLEMENTS_OUTPUT="$INSTALL_ROOT/muesli-entitlements.plist"

cleanup() {
  rm -rf "$INSTALL_ROOT"
}
trap cleanup EXIT

echo "Building isolated app bundle in $INSTALL_ROOT"
MUESLI_INSTALL_DIR="$INSTALL_ROOT" \
MUESLI_APP_BUNDLE_NAME="$APP_BUNDLE_NAME" \
MUESLI_SKIP_SIGN=1 \
"$ROOT/scripts/build_native_app.sh" "$BUILD_CONFIG"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected packaged app at $APP_PATH" >&2
  exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "Missing app executable at $APP_BIN" >&2
  exit 1
fi

if [[ ! -x "$CLI_BIN" ]]; then
  echo "Missing CLI executable at $CLI_BIN" >&2
  exit 1
fi

SWIFTPM_RESOURCE_BUNDLES=(
  MuesliNative_MuesliNativeApp.bundle
  DTLNAecCoreML_DTLNAec512.bundle
  TelemetryDeck_TelemetryDeck.bundle
)
for bundle_name in "${SWIFTPM_RESOURCE_BUNDLES[@]}"; do
  if [[ ! -d "$APP_PATH/Contents/Resources/$bundle_name" ]]; then
    echo "Packaged app is missing canonical SwiftPM resources: $bundle_name" >&2
    exit 1
  fi
  if [[ -e "$APP_PATH/$bundle_name" ]]; then
    echo "SwiftPM resource bundle must not be placed at the signed app root: $bundle_name" >&2
    exit 1
  fi
done

if [[ ! -e "$LOCALVQE_LIBRARY" || ! -f "$LOCALVQE_GTCRN_MODEL" || ! -f "$LOCALVQE_V12_MODEL" ]]; then
  echo "Packaged app is missing its LocalVQE runtime or one of its models." >&2
  exit 1
fi

codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_OUTPUT" 2>/dev/null
if grep -q 'com.apple.developer.icloud' "$ENTITLEMENTS_OUTPUT"; then
  echo "Ad-hoc packaged app unexpectedly contains restricted iCloud entitlements." >&2
  exit 1
fi

"$CLI_BIN" spec > "$SPEC_OUTPUT"
"$CLI_BIN" transcribe --help > "$TRANSCRIBE_HELP_OUTPUT"
"$APP_BIN" --packaged-resource-smoke-test

if ! grep -q '"command" : "homan-cli spec"' "$SPEC_OUTPUT"; then
  echo "Packaged CLI did not return the expected spec payload." >&2
  cat "$SPEC_OUTPUT" >&2
  exit 1
fi

if ! grep -q 'USAGE: homan-cli transcribe' "$TRANSCRIBE_HELP_OUTPUT"; then
  echo "Packaged CLI did not return transcribe help." >&2
  cat "$TRANSCRIBE_HELP_OUTPUT" >&2
  exit 1
fi

echo "Packaged CLI smoke test passed."
echo "Verified:"
echo "  - $APP_BIN"
echo "  - $CLI_BIN"
echo "  - packaged GUI resource lookup"
echo "  - bundled LocalVQE runtime and both models"
