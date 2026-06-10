#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build

# Doc snippet sync check — fails fast if any <!-- include: ... --> block in
# README/BELIEFS/CLAUDE has drifted from its source file.
python3 docs/sync.py --check

# The LaunchAgent template daemonctl.sh install writes must stay valid XML.
scripts/daemonctl.sh print-plist | plutil -lint -

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
  Tests/DisplayDDCTests.swift
  Tests/AppsTests.swift
  Tests/AudioTests.swift
  Tests/AudioProcessesTests.swift
  Tests/AXTests.swift
  Tests/DevicesTests.swift
  Tests/DisplayTests.swift
  Tests/InputTests.swift
  Tests/NetworkTests.swift
  Tests/NLPTests.swift
  Tests/NotifyTests.swift
  Tests/StorageTests.swift
  Tests/ThumbnailsTests.swift
  Tests/VisionTests.swift
  Tests/WindowsTests.swift
  Tests/OverlayTests.swift
  Tests/ProcTests.swift
  Tests/SensorsTests.swift
  Tests/SpeechTTSTests.swift
  Tests/SpotlightOneShotTests.swift
  Tests/HTTPServerTests.swift
  Tests/LocationTests.swift
  Tests/BroadcastsTests.swift
  Tests/URLHandlerTests.swift
  Tests/URLSchemeHandlerTests.swift
  Tests/RefCountedObserverTests.swift
  Tests/StackScopeTests.swift
  Tests/FileWatcherTests.swift
  Tests/StackSourceTests.swift
  Tests/SafePredicateTests.swift
  Tests/CLITests.swift
  Tests/TemplateEngineTests.swift
  Tests/SignalFirstTests.swift
  Tests/ResetInjectionTests.swift
  Tests/WindowConfigureTests.swift
  Tests/BangRegistryTests.swift
  Tests/HandlersRegisterTests.swift
  Tests/HeadlessStackTests.swift
  Tests/TimerTests.swift
  Tests/UtilTests.swift
  Tests/DisplayHelpersTests.swift
  Tests/MaterialTests.swift
  Tests/WindowLifecycleTests.swift
  Tests/WindowChannelTests.swift
  Tests/AnchorTests.swift
  Tests/MenubarFrameTests.swift
  Tests/MousePayloadTests.swift
  Tests/WindowsChangedTests.swift
  Tests/DisplaysChangedTests.swift
  Tests/MenubarChangedTests.swift
  Tests/ComputeDeltaTests.swift
  Tests/ChannelsRegistryTests.swift
  Tests/WindowsLifecycleObserverTests.swift
  Tests/CrashBackoffTests.swift
  Tests/PermissionsRegistryTests.swift
  Tests/main.swift
)

C_SOURCES=(
  Sources/C/TouchEvents.c
  Sources/C/SafePredicate.m
)

# Pre-compile C / ObjC sources to .o. When the combined Swift source list
# grows past a swiftc-internal threshold (hit after Bridge was split across
# multiple BridgeXxx.swift files in 2026-06), swiftc silently drops the
# `-x c` / `-x objective-c` invocations for any .c/.m args, then ld bails
# with "unknown file type". Build.sh doesn't hit the threshold so this
# bypass is only needed for the test target. Apple-side bug.
#
# Recompile only when the source is newer than the .o (mtime gate). Avoids
# the "input file modified during the build" race swiftc raises when its
# arg files change inside one invocation — every test run was rebuilding
# the .o files and swiftc would catch them mid-compile otherwise.
mkdir -p .build/test-obj
if [[ Sources/C/TouchEvents.c -nt .build/test-obj/TouchEvents.o ]]; then
  clang -c -Wno-zero-length-array -fobjc-arc \
    -target arm64-apple-macos13.0 \
    -o .build/test-obj/TouchEvents.o Sources/C/TouchEvents.c
fi
if [[ Sources/C/SafePredicate.m -nt .build/test-obj/SafePredicate.o ]]; then
  clang -c -Wno-zero-length-array -fobjc-arc \
    -target arm64-apple-macos13.0 \
    -o .build/test-obj/SafePredicate.o Sources/C/SafePredicate.m
fi

swiftc \
  -o .build/stackd-tests \
  "${SWIFT_SOURCES[@]}" "${TEST_SOURCES[@]}" \
  .build/test-obj/TouchEvents.o .build/test-obj/SafePredicate.o \
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
