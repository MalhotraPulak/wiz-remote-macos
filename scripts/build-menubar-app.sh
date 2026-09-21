#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/WiZ Remote Menu Bar.app"
CONTENTS_DIR="$APP_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MACOS_DIR="$CONTENTS_DIR/MacOS"
ICON_SOURCE="$PROJECT_DIR/WizRemote/Assets.xcassets/AppIcon.appiconset/wizmac.png"

cd "$PROJECT_DIR"
BUILD_DIR="$PROJECT_DIR/.build/menubar-release"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/menubar-overlay-module-cache"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"
SWIFT_EXTRA_OPTIONS=()

# Some Command Line Tools installations contain two SwiftBridging module maps.
# Use the same non-invasive overlay workaround as the full app build.
SWIFT_INCLUDE_DIR="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ -f "$SWIFT_INCLUDE_DIR/module.modulemap" && -f "$SWIFT_INCLUDE_DIR/bridging.modulemap" ]]; then
    SWIFT_EXTRA_OPTIONS+=(
        -vfsoverlay "$PROJECT_DIR/Packaging/toolchain-overlay.yaml"
    )
fi

swiftc \
    -parse-as-library \
    -O \
    -sdk "$SDK_PATH" \
    -target "$ARCHITECTURE-apple-macosx13.0" \
    -framework Accelerate \
    -framework AppKit \
    -framework CoreAudio \
    -framework ServiceManagement \
    -framework SwiftUI \
    "${SWIFT_EXTRA_OPTIONS[@]}" \
    "$PROJECT_DIR/WizRemote/BulbService.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/LaunchAtLoginController.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/SystemAudioCapture.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/WizRealtimeSender.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/MusicSyncController.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/MusicSyncPanel.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/MenuBarContentView.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/WizRemoteMenuBarApp.swift" \
    -o "$BUILD_DIR/WizRemoteMenuBar"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
install -m 755 "$BUILD_DIR/WizRemoteMenuBar" "$MACOS_DIR/WizRemoteMenuBar"
install -m 644 "$PROJECT_DIR/Packaging/MenuBar-Info.plist" "$CONTENTS_DIR/Info.plist"
install -m 644 "$ICON_SOURCE" "$RESOURCES_DIR/wizmac.png"

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
