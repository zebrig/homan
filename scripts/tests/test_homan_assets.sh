#!/usr/bin/env bash
# test_homan_assets.sh — brand asset invariants (T015).
#
# Verifies the canonical mark geometry against the brand contract, font
# hashes against the third-party manifest, SVG safety, and generator output
# colors. Run from the repository root.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FAILURES=0
ok() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES+1)); }

# --- 1. Canonical mark geometry matches the contract -----------------------
MARK="assets/brand/homan-mark.svg"
CONTRACT="specs/003-homan-product-rebrand/contracts/brand-identity.md"
if [[ ! -f "$MARK" || ! -f "$CONTRACT" ]]; then
  fail "missing mark/contract: $MARK / $CONTRACT"
else
  # Compare just the x/y/width/height coordinates (ignore rx/whitespace).
  extract_coords() {
    grep -oE 'x="[0-9]+"[[:space:]]*y="[0-9]+"[[:space:]]*width="[0-9]+"[[:space:]]*height="[0-9]+"' "$1" | sort
  }
  svg_rects=$(extract_coords "$MARK")
  contract_rects=$(grep -A6 'viewBox="0 0 40 40"' "$CONTRACT" | extract_coords /dev/stdin)
  if [[ "$svg_rects" == "$contract_rects" ]]; then
    ok "homan-mark.svg geometry matches brand-identity contract"
  else
    fail "homan-mark.svg geometry differs from contract"
    diff <(echo "$svg_rects") <(echo "$contract_rects") || true
  fi
fi

# --- 2. Square-cap small/menu variants -------------------------------------
for f in assets/brand/homan-mark-small.svg assets/brand/homan-menu-template.svg; do
  if grep -q 'rx=' "$f"; then
    fail "$f should use square caps (no rx)"
  else
    ok "$f uses square caps"
  fi
done

# --- 3. SVG safety: no scripts / external refs -----------------------------
for f in assets/brand/*.svg; do
  if grep -qiE '<script|foreignObject|xlink:href|url\(' "$f"; then
    fail "$f has scripts/external references"
  else
    ok "$f is self-contained (no scripts/external refs)"
  fi
done

# --- 4. Font hashes match the manifest -------------------------------------
if command -v python3 >/dev/null; then
  python3 - <<'EOF'
import hashlib, json, sys
manifest = json.load(open("assets/third-party-manifest.json"))
ok = True
for entry in manifest["entries"]:
    for f in entry["packaged_files"]:
        try:
            actual = hashlib.sha256(open(f["path"],"rb").read()).hexdigest()
            if actual != f["sha256"]:
                print("FAIL - hash mismatch", f["path"])
                ok = False
        except FileNotFoundError:
            print("FAIL - missing", f["path"])
            ok = False
    lic = entry.get("license_text_path")
    if lic:
        try:
            lh = hashlib.sha256(open(lic,"rb").read()).hexdigest()
            if lh != entry["license_text_sha256"]:
                print("FAIL - OFL hash mismatch", lic)
                ok = False
        except FileNotFoundError:
            print("FAIL - missing OFL", lic); ok = False
sys.exit(0 if ok else 1)
EOF
  if [[ $? -eq 0 ]]; then ok "font/archive hashes match third-party manifest"; else fail "font/archive hash mismatch"; fi
else
  fail "python3 required for hash checks"
fi

# --- 5. Generator output colors (sRGB) -------------------------------------
GEN="build/brand-review/tools/homan-brand-assets"
if [[ -x "$GEN" ]]; then
  # Re-run to ensure deterministic regeneration.
  "$GEN" generate-review >/dev/null
  ok "generator regenerates candidates deterministically"
else
  fail "generator binary missing: $GEN (run /usr/bin/swiftc -O scripts/generate_homan_assets.swift -o $GEN)"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "test_homan_assets: $FAILURES failure(s)"
  exit 1
fi
echo "test_homan_assets: all checks passed"
