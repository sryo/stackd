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
  Sources/Bridge.swift
  Sources/IPC.swift
  Sources/CLI.swift
  Sources/FileWatcher.swift
  Sources/DataSources/Battery.swift
  Sources/DataSources/Mouse.swift
  Sources/DataSources/Hotkey.swift
  Sources/DataSources/EventTap.swift
  Sources/DataSources/Workspace.swift
  Sources/DataSources/Gesture.swift
  Sources/DataSources/Appearance.swift
  Sources/DataSources/Input.swift
  Sources/DataSources/Defaults.swift
  Sources/DataSources/NetSource.swift
  Sources/DataSources/Audio.swift
  Sources/DataSources/Display.swift
  Sources/DataSources/MenuBar.swift
  Sources/DataSources/Media.swift
  Sources/DataSources/Settings.swift
  Sources/DataSources/FS.swift
  Sources/DataSources/Pasteboard.swift
  Sources/DataSources/Proc.swift
  Sources/DataSources/EventsSynthesize.swift
  Sources/DataSources/Apps.swift
  Sources/DataSources/Icons.swift
  Sources/DataSources/AX.swift
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
  -framework WebKit \
  -framework IOKit \
  -framework Carbon \
  -target arm64-apple-macos13.0

# Stage Runtime next to the binary so URLSchemeHandler can find it via
# Bundle.main.executableURL. (Eventually this becomes Contents/Resources/Runtime
# inside a .app bundle.) Symlink during dev so edits propagate without rebuild.
ln -sfn "$(pwd)/Runtime" .build/Runtime

echo "Built .build/stackd"
