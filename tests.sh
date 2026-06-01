#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build

# Derive the production source list from build.sh so we don't have to keep
# two lists in sync. Drop Sources/main.swift — Tests/main.swift replaces it
# as the entry point.
SWIFT_SOURCES=()
while IFS= read -r f; do
  [[ "$f" == "Sources/main.swift" ]] || SWIFT_SOURCES+=("$f")
done < <(awk '
  /^SWIFT_SOURCES=\(/ { in_arr=1; next }
  in_arr && /^\)/     { in_arr=0; next }
  in_arr && /Sources\// { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }
' build.sh)

# Test files. Tests/main.swift must come last so its top-level statements
# act as the entry point.
TEST_SOURCES=(
  Tests/Harness.swift
  Tests/JSHarness.swift
  Tests/ChannelInferenceTests.swift
  Tests/BridgeJsonifyTests.swift
  Tests/StackDoctorTests.swift
  Tests/UpdateParserTests.swift
  Tests/HostDiskIOTests.swift
  Tests/BonjourTests.swift
  Tests/CalendarTests.swift
  Tests/SpotlightLiveTests.swift
  Tests/CameraStreamTests.swift
  Tests/SpeechSTTTests.swift
  Tests/MenubarItemsTests.swift
  Tests/AppIntentsTests.swift
  Tests/PrivacyRecordingTests.swift
  Tests/TemplateEngineTests.swift
  Tests/main.swift
)

C_SOURCES=(
  Sources/C/TouchEvents.c
)

swiftc \
  -o .build/stackd-tests \
  "${SWIFT_SOURCES[@]}" "${TEST_SOURCES[@]}" "${C_SOURCES[@]}" \
  -import-objc-header Sources/C/StackdBridge.h \
  -Xcc -Wno-zero-length-array \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework CoreLocation \
  -framework CoreVideo \
  -framework DiskArbitration \
  -framework EventKit \
  -framework IOBluetooth \
  -framework IOKit \
  -framework JavaScriptCore \
  -framework MultitouchSupport \
  -framework NaturalLanguage \
  -framework OSAKit \
  -framework QuickLookThumbnailing \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework WebKit \
  -F "$(xcrun --sdk macosx --show-sdk-path)/System/Library/PrivateFrameworks" \
  -target arm64-apple-macos13.0

echo "Built .build/stackd-tests"
echo
exec .build/stackd-tests
