#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build

# Regenerate the served Runtime/api.js artifact from Runtime/src/ modules.
scripts/build-runtime.sh

# Every Swift file under Sources/. tests.sh derives its list the same way,
# so a new file is picked up by both without editing either script.
SWIFT_SOURCES=()
while IFS= read -r f; do
  SWIFT_SOURCES+=("$f")
done < <(find Sources -name '*.swift' | LC_ALL=C sort)

C_SOURCES=(
  Sources/C/TouchEvents.c
  Sources/C/SafePredicate.m
)

swiftc -O \
  -o .build/stackd \
  "${SWIFT_SOURCES[@]}" "${C_SOURCES[@]}" \
  -import-objc-header Sources/C/StackdBridge.h \
  -Xcc -Wno-zero-length-array \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker Sources/Info.plist \
  -framework AppKit \
  -framework AppIntents \
  -framework AVFoundation \
  -framework Carbon \
  -framework CoreLocation \
  -framework CoreVideo \
  -framework DiskArbitration \
  -framework EventKit \
  -framework IOBluetooth \
  -framework IOKit \
  -framework MultitouchSupport \
  -framework NaturalLanguage \
  -framework OSAKit \
  -framework QuickLookThumbnailing \
  -framework ScreenCaptureKit \
  -framework Speech \
  -framework Vision \
  -framework WebKit \
  -F "$(xcrun --sdk macosx --show-sdk-path)/System/Library/PrivateFrameworks" \
  -target arm64-apple-macos13.0

# Stable code signature so TCC trust (Accessibility → CGEventTap) survives
# rebuilds. The linker's ad-hoc signature changes on every build; under
# launchd the daemon is its own TCC identity, so an unstable signature
# silently disables eventtaps after each rebuild (terminal-spawned daemons
# never hit this — they inherit the terminal's trust). Prefer Developer ID
# (multi-year validity) over Apple Development (yearly expiry); skip when no
# identity exists (CI) — the ad-hoc signature is fine there.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}')
[[ -z "$SIGN_ID" ]] && SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
if [[ -n "$SIGN_ID" ]]; then
  codesign -f -s "$SIGN_ID" .build/stackd
  echo "Signed .build/stackd ($SIGN_ID)"
fi

# Stage Runtime next to the binary so URLSchemeHandler can find it via
# Bundle.main.executableURL. (Eventually this becomes Contents/Resources/Runtime
# inside a .app bundle.) Symlink during dev so edits propagate without rebuild.
ln -sfn "$(pwd)/Runtime" .build/Runtime

echo "Built .build/stackd"
