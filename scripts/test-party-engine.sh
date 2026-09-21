#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/party-engine-test"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/party-engine-test-module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"
cd "$PROJECT_DIR"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"
SWIFT_EXTRA_OPTIONS=()

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
    -framework CoreAudio \
    "${SWIFT_EXTRA_OPTIONS[@]}" \
    "$PROJECT_DIR/WizRemoteMenuBar/SystemAudioCapture.swift" \
    "$PROJECT_DIR/WizRemoteMenuBar/PartyLightEngine.swift" \
    "$PROJECT_DIR/Tests/PartyLightEngineSmokeTest.swift" \
    -o "$BUILD_DIR/PartyLightEngineSmokeTest"

"$BUILD_DIR/PartyLightEngineSmokeTest"
