#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${HOMAN_INSTALL_APP_PATH:-/Applications/Homan.app}"
INSTALL_DIR="$(dirname "$APP_PATH")"
APP_BUNDLE_NAME="$(basename "$APP_PATH")"
STAGING_INSTALL_DIR="${HOMAN_STAGING_INSTALL_DIR:-$ROOT/build/owner-signed-install}"
STAGED_APP_PATH="$STAGING_INSTALL_DIR/$APP_BUNDLE_NAME"
BACKUP_DIR="${HOMAN_INSTALL_BACKUP_DIR:-$ROOT/build/owner-signed-backup}"
BACKUP_APP_PATH="$BACKUP_DIR/$APP_BUNDLE_NAME"
SIGN_IDENTITY="${HOMAN_SIGN_IDENTITY:-Developer ID Application: Yahor Zaleski (YH3W46ABZY)}"
EXPECTED_TEAM_ID="${HOMAN_TEAM_ID:-YH3W46ABZY}"
NOTARY_PROFILE="${HOMAN_NOTARY_PROFILE:-HomanNotary}"
ENTITLEMENTS="${HOMAN_ENTITLEMENTS:-$ROOT/scripts/MuesliLocalOnly.entitlements}"
SUPPORT_DB="${HOMAN_SUPPORT_DB:-$HOME/Library/Application Support/Homan/muesli.db}"
NOTARIZE=0
LAUNCH=1

usage() {
  cat <<'EOF'
Usage: ./scripts/install_homan_local.sh [--notarize] [--no-launch]

Builds and installs owner-signed /Applications/Homan.app. The default path uses
Yahor Zaleski's Developer ID, local-only Homan entitlements, hardened runtime,
and a secure timestamp. --notarize additionally submits to Apple with HomanNotary.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) NOTARIZE=1 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$APP_BUNDLE_NAME" != "Homan.app" ]]; then
  echo "Refusing unexpected app bundle name: $APP_BUNDLE_NAME" >&2
  exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Homan entitlements not found: $ENTITLEMENTS" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\""; then
  echo "Required Homan signing identity not found: $SIGN_IDENTITY" >&2
  exit 1
fi

if [[ -f "$SUPPORT_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
  ACTIVE_MEETING_COUNT="$(sqlite3 -readonly "$SUPPORT_DB" \
    "SELECT COUNT(*) FROM meetings WHERE deleted_at IS NULL AND meeting_status IN ('recording','processing');")"
  if [[ "$ACTIVE_MEETING_COUNT" != "0" ]]; then
    echo "Refusing to replace Homan while $ACTIVE_MEETING_COUNT meeting(s) are recording or processing." >&2
    exit 1
  fi
fi

echo "Building owner-signed Homan in repository-local staging..."
MUESLI_INSTALL_DIR="$STAGING_INSTALL_DIR" \
MUESLI_APP_BUNDLE_NAME="$APP_BUNDLE_NAME" \
MUESLI_SIGN_IDENTITY="$SIGN_IDENTITY" \
MUESLI_ENTITLEMENTS="$ENTITLEMENTS" \
MUESLI_SKIP_SIGN=0 \
  "$ROOT/scripts/build_native_app.sh" release

echo "Verifying staged Homan signature identity..."
codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH"
SIGNATURE_DETAILS="$(codesign -dvvv "$STAGED_APP_PATH" 2>&1)"
grep -Fq "Authority=$SIGN_IDENTITY" <<< "$SIGNATURE_DETAILS" || {
  echo "Installed Homan has the wrong signing Authority." >&2
  exit 1
}
grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$SIGNATURE_DETAILS" || {
  echo "Installed Homan has the wrong TeamIdentifier." >&2
  exit 1
}
grep -Fq "Identifier=com.zebrig.homan" <<< "$SIGNATURE_DETAILS" || {
  echo "Installed Homan has the wrong bundle identifier." >&2
  exit 1
}
grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<< "$SIGNATURE_DETAILS" || {
  echo "Installed Homan is missing the hardened-runtime signature flag." >&2
  exit 1
}
EMBEDDED_ENTITLEMENTS="$(codesign -d --entitlements - "$STAGED_APP_PATH" 2>&1)"
for required_entitlement in \
  com.apple.security.device.audio-input \
  com.apple.security.personal-information.calendars \
  com.apple.security.automation.apple-events; do
  grep -Fq "[Key] $required_entitlement" <<< "$EMBEDDED_ENTITLEMENTS" || {
    echo "Staged Homan is missing entitlement: $required_entitlement" >&2
    exit 1
  }
done
if grep -Fq "com.apple.developer.icloud-container" <<< "$EMBEDDED_ENTITLEMENTS"; then
  echo "Staged Homan unexpectedly contains inherited Muesli iCloud entitlements." >&2
  exit 1
fi

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Notarizing and stapling Homan with profile $NOTARY_PROFILE..."
  MUESLI_NOTARY_PROFILE="$NOTARY_PROFILE" \
    "$ROOT/scripts/notarize_app.sh" "$STAGED_APP_PATH"
fi

# Keep the installed app running throughout compilation and signing. Only after
# the staged bundle has passed every verification do we request a graceful quit.
if pgrep -x Homan >/dev/null 2>&1; then
  set +e
  osascript -e 'tell application id "com.zebrig.homan" to quit'
  QUIT_STATUS=$?
  set -e
  # A protected meeting can make the initial Apple event return -128 while Homan
  # presents its own Quit Anyway confirmation. Allow time for that response.
  for _ in {1..300}; do
    pgrep -x Homan >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x Homan >/dev/null 2>&1; then
    if [[ "$QUIT_STATUS" != "0" ]]; then
      echo "Homan declined the quit request because it is protecting active in-memory work." >&2
    fi
    echo "The signed build is safe at: $STAGED_APP_PATH" >&2
    echo "Stop the active meeting/processing task or choose Quit Anyway, then run this command again." >&2
    exit 1
  fi
fi

echo "Installing verified owner-signed Homan..."
mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"
rm -rf "$BACKUP_APP_PATH"
if [[ -d "$APP_PATH" ]]; then
  mv "$APP_PATH" "$BACKUP_APP_PATH"
fi
if ! ditto "$STAGED_APP_PATH" "$APP_PATH"; then
  rm -rf "$APP_PATH"
  if [[ -d "$BACKUP_APP_PATH" ]]; then
    mv "$BACKUP_APP_PATH" "$APP_PATH"
  fi
  echo "Installation failed; restored the previous Homan bundle." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
INSTALLED_SIGNATURE_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1)"
grep -Fq "Authority=$SIGN_IDENTITY" <<< "$INSTALLED_SIGNATURE_DETAILS"
grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$INSTALLED_SIGNATURE_DETAILS"
grep -Fq "Identifier=com.zebrig.homan" <<< "$INSTALLED_SIGNATURE_DETAILS"

if [[ "$LAUNCH" == "1" ]]; then
  open -a "$APP_PATH"
fi

echo "Installed owner-signed Homan: $APP_PATH"
echo "  Authority: $SIGN_IDENTITY"
echo "  Team ID:   $EXPECTED_TEAM_ID"
echo "  Notarized: $([[ "$NOTARIZE" == "1" ]] && echo yes || echo no)"
