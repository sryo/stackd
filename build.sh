#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build

# Regenerate the served Runtime/api.js artifact from Runtime/src/ modules.
scripts/build-runtime.sh

SWIFT_SOURCES=(
  Sources/main.swift
  Sources/AppDelegate.swift
  Sources/StackWindow.swift
  Sources/PassthroughWebView.swift
  Sources/StackMaterial.swift
  Sources/StackHost.swift
  Sources/StackSource.swift
  Sources/URLSchemeHandler.swift
  Sources/StackScope.swift
  Sources/Private/SkyLight.swift

  Sources/RefCountedObserver.swift

  Sources/Bridge.swift
  Sources/BridgeApps.swift
  Sources/BridgeAudio.swift
  Sources/BridgeAX.swift
  Sources/BridgeBonjour.swift
  Sources/BridgeBroadcasts.swift
  Sources/BridgeCaffeinate.swift
  Sources/BridgeCalendar.swift
  Sources/BridgeCamera.swift
  Sources/BridgeChannels.swift
  Sources/BridgeDisplay.swift
  Sources/BridgeEvents.swift
  Sources/BridgeFS.swift
  Sources/BridgeHTTP.swift
  Sources/BridgeHotkey.swift
  Sources/BridgeJSON.swift
  Sources/BridgeMenubar.swift
  Sources/BridgeNLP.swift
  Sources/BridgeOverlay.swift
  Sources/BridgeProc.swift
  Sources/BridgeSQLite.swift
  Sources/BridgeSearch.swift
  Sources/BridgeStorage.swift
  Sources/BridgeURLHandler.swift
  Sources/BridgeWindow.swift
  Sources/BridgeWindows.swift
  Sources/Deltas.swift
  Sources/Channels.swift
  Sources/Permissions.swift
  Sources/IPC.swift
  Sources/CLI.swift
  Sources/StackTemplates.swift
  Sources/FileWatcher.swift
  Sources/DataSources/Calendar.swift

  Sources/DataSources/Windows.swift

  Sources/DataSources/Input.swift
  Sources/DataSources/Location.swift
  Sources/DataSources/Broadcasts.swift
  Sources/DataSources/URLHandler.swift
  Sources/DataSources/Menubar.swift


  Sources/DataSources/Network.swift
  Sources/DataSources/Audio.swift
  Sources/DataSources/Display.swift
  Sources/DataSources/DisplayDDC.swift
  Sources/DataSources/Sensors.swift

  Sources/DataSources/Storage.swift
  Sources/DataSources/Proc.swift
  Sources/DataSources/Apps.swift
  Sources/DataSources/AX.swift
  Sources/DataSources/Overlay.swift
  Sources/DataSources/HTTPServer.swift
  Sources/DataSources/Bonjour.swift
  Sources/DataSources/Vision.swift
  Sources/DataSources/NLP.swift
  Sources/DataSources/Spotlight.swift
  Sources/DataSources/Speech.swift
  Sources/DataSources/Thumbnails.swift
  Sources/DataSources/Update.swift
  Sources/DataSources/Notify.swift
  Sources/DataSources/Devices.swift
  Sources/DataSources/Camera.swift
  Sources/DataSources/AppIntents.swift
  Sources/DataSources/Privacy.swift
)

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
