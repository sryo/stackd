#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build

SWIFT_SOURCES=(
  Sources/main.swift
  Sources/AppDelegate.swift
  Sources/StackWindow.swift
  Sources/StackHost.swift
  Sources/URLSchemeHandler.swift
  Sources/StackScope.swift
  Sources/Private/SkyLight.swift

  Sources/RefCountedObserver.swift

  Sources/Bridge.swift
  Sources/IPC.swift
  Sources/CLI.swift
  Sources/StackTemplates.swift
  Sources/FileWatcher.swift
  Sources/DataSources/Battery.swift
  Sources/DataSources/Camera.swift
  Sources/DataSources/Mouse.swift
  Sources/DataSources/Cursor.swift
  Sources/DataSources/HotCorners.swift
  Sources/DataSources/Hotkey.swift
  Sources/DataSources/Events.swift

  Sources/DataSources/App.swift
  Sources/DataSources/Windows.swift
  Sources/DataSources/WindowEvents.swift
  Sources/DataSources/MissionControl.swift

  Sources/DataSources/Gesture.swift
  Sources/DataSources/Appearance.swift
  Sources/DataSources/AppleScript.swift
  Sources/DataSources/Host.swift
  Sources/DataSources/Input.swift
  Sources/DataSources/Location.swift
  Sources/DataSources/Defaults.swift
  Sources/DataSources/Broadcasts.swift
  Sources/DataSources/Menubar.swift
  Sources/DataSources/Menu.swift


  Sources/DataSources/Network.swift
  Sources/DataSources/Audio.swift
  Sources/DataSources/Display.swift
  Sources/DataSources/DisplaySnapshot.swift
  Sources/DataSources/Media.swift
  Sources/DataSources/Settings.swift
  Sources/DataSources/Sensors.swift

  Sources/DataSources/Sound.swift
  Sources/DataSources/FS.swift
  Sources/DataSources/Pasteboard.swift
  Sources/DataSources/Proc.swift
  Sources/DataSources/Apps.swift
  Sources/DataSources/Icons.swift
  Sources/DataSources/AX.swift
  Sources/DataSources/Spaces.swift
  Sources/DataSources/Caffeinate.swift
  Sources/DataSources/Disks.swift
  Sources/DataSources/DisplayLink.swift
  Sources/DataSources/HTTPServer.swift
  Sources/DataSources/VisionOCR.swift
  Sources/DataSources/VisionFaces.swift
  Sources/DataSources/VisionFeaturePrint.swift
  Sources/DataSources/VisionSubjectMask.swift
  Sources/DataSources/VisionBodyPose.swift
  Sources/DataSources/SQLite.swift
  Sources/DataSources/NLP.swift
  Sources/DataSources/Notify.swift
  Sources/DataSources/TouchDevice.swift
  Sources/DataSources/USB.swift
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
  -framework AVFoundation \
  -framework Carbon \
  -framework CoreLocation \
  -framework CoreVideo \
  -framework DiskArbitration \
  -framework IOKit \
  -framework MultitouchSupport \
  -framework NaturalLanguage \
  -framework OSAKit \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework WebKit \
  -F /System/Library/PrivateFrameworks \
  -target arm64-apple-macos13.0

# Stage Runtime next to the binary so URLSchemeHandler can find it via
# Bundle.main.executableURL. (Eventually this becomes Contents/Resources/Runtime
# inside a .app bundle.) Symlink during dev so edits propagate without rebuild.
ln -sfn "$(pwd)/Runtime" .build/Runtime

echo "Built .build/stackd"
