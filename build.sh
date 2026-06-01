#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build

SWIFT_SOURCES=(
  Sources/main.swift
  Sources/AppDelegate.swift
  Sources/StackWindow.swift
  Sources/StackHost.swift
  Sources/StackSource.swift
  Sources/URLSchemeHandler.swift
  Sources/StackScope.swift
  Sources/Private/SkyLight.swift

  Sources/RefCountedObserver.swift

  Sources/Bridge.swift
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
)

swiftc -O \
  -o .build/stackd \
  "${SWIFT_SOURCES[@]}" "${C_SOURCES[@]}" \
  -import-objc-header Sources/C/StackdBridge.h \
  -Xcc -Wno-zero-length-array \
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

# Stage Runtime next to the binary so URLSchemeHandler can find it via
# Bundle.main.executableURL. (Eventually this becomes Contents/Resources/Runtime
# inside a .app bundle.) Symlink during dev so edits propagate without rebuild.
ln -sfn "$(pwd)/Runtime" .build/Runtime

echo "Built .build/stackd"
