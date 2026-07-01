#!/usr/bin/env bash
# package-app.sh — assemble .build/stackd into a relocatable stackd.app bundle
# and (by default) install it to /Applications so it can autostart via launchd.
#
# Layout produced:
#   stackd.app/Contents/Info.plist            (Sources/Info.plist, verbatim)
#   stackd.app/Contents/MacOS/stackd          (the daemon binary)
#   stackd.app/Contents/Resources/Runtime/    (api.js stdlib — copied, not symlinked)
#
# runtimePath() finds Runtime via ../Resources from the executable dir, so the
# bundle is self-contained and can live anywhere. Signed with Developer ID when
# available (stable identity → TCC/Accessibility trust survives reinstalls).
#
# Usage:
#   scripts/package-app.sh            # build, package, install to /Applications
#   scripts/package-app.sh --here     # package into .build/stackd.app, no install
#   STACKD_APP_DEST=/path scripts/package-app.sh   # custom install dir

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL=1
[[ "${1:-}" == "--here" ]] && INSTALL=0

DEST_DIR="${STACKD_APP_DEST:-/Applications}"
STAGE="$REPO_ROOT/.build/stackd.app"

log() { printf '[package-app] %s\n' "$*" >&2; }

# 1. Build the binary (regenerates Runtime/api.js from src too).
log "building daemon"
./build.sh >/dev/null

# 2. Assemble the bundle in .build (clean each time so removed files don't linger).
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp Sources/Info.plist "$STAGE/Contents/Info.plist"
cp .build/stackd "$STAGE/Contents/MacOS/stackd"
# Resolve the Runtime symlink to a real copy so the bundle is self-contained.
cp -RL Runtime "$STAGE/Contents/Resources/Runtime"
log "assembled $STAGE"

# 3. Sign the whole bundle with a stable identity (Developer ID preferred).
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}')
[[ -z "$SIGN_ID" ]] && SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
if [[ -n "$SIGN_ID" ]]; then
  codesign -f -s "$SIGN_ID" --deep "$STAGE"
  log "signed bundle ($SIGN_ID)"
else
  log "no signing identity — bundle stays ad-hoc (TCC trust won't persist reinstalls)"
fi

if [[ "$INSTALL" -eq 0 ]]; then
  log "done (--here): $STAGE"
  exit 0
fi

# 4. Install to the destination, replacing any prior copy.
APP_PATH="$DEST_DIR/stackd.app"
if [[ -d "$APP_PATH" ]]; then
  log "replacing existing $APP_PATH"
  rm -rf "$APP_PATH"
fi
cp -R "$STAGE" "$APP_PATH"
log "installed $APP_PATH"
printf '%s\n' "$APP_PATH"
