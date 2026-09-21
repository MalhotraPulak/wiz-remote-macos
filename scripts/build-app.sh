#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/WiZ Remote.app"
CONTENTS_DIR="$APP_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MACOS_DIR="$CONTENTS_DIR/MacOS"
ICON_SOURCE="$PROJECT_DIR/WizRemote/Assets.xcassets/AppIcon.appiconset/wizmac.png"

cd "$PROJECT_DIR"
BUILD_DIR="$PROJECT_DIR/.build/release"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/overlay-module-cache"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"
SWIFT_EXTRA_OPTIONS=()

# Command Line Tools can occasionally retain both the old module.modulemap and
# the newer bridging.modulemap, which each define SwiftBridging. Mask the stale
# file for this build without changing anything under /Library/Developer.
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
    -framework AppKit \
    -framework AVFoundation \
    -framework SwiftUI \
    "${SWIFT_EXTRA_OPTIONS[@]}" \
    "$PROJECT_DIR/WizRemote/BulbService.swift" \
    "$PROJECT_DIR/WizRemote/ContentView.swift" \
    "$PROJECT_DIR/WizRemote/WizRemoteApp.swift" \
    -o "$BUILD_DIR/WizRemote"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
install -m 755 "$BUILD_DIR/WizRemote" "$MACOS_DIR/WizRemote"
install -m 644 "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
install -m 644 "$PROJECT_DIR/WizRemote/on.wav" "$RESOURCES_DIR/on.wav"
install -m 644 "$PROJECT_DIR/WizRemote/off.wav" "$RESOURCES_DIR/off.wav"
install -m 644 "$ICON_SOURCE" "$RESOURCES_DIR/wizmac.png"

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
