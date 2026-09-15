#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_ROOT="${1:?Usage: bash scripts/test-native-hardened.sh SDK_ROOT ENTITLEMENTS}"
ENTITLEMENTS="${2:?Pass Duckpad.entitlements}"
BUILD_ROOT="$(mktemp -d /tmp/duckpad-native-hardened.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
APP="$BUILD_ROOT/NativeSmoke.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_ROOT/Consent"
swiftc -swift-version 6 -parse-as-library -I "$SDK_ROOT/include" "${DUCKPAD_NATIVE_SMOKE_SOURCE:-native/Tests/NativeSmoke.swift}" -o "$APP/Contents/MacOS/NativeSmoke"
ditto dist/native/com.duckpad.clipboard-history.duckpad-plugin "$APP/Contents/Resources/Clipboard.duckpad-plugin"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.namjeongwan.duckpad.native-smoke</string><key>CFBundleExecutable</key><string>NativeSmoke</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "${DUCKPAD_NATIVE_SAVE_PANEL_SMOKE:-0}" == "1" ]]; then
    "$APP/Contents/MacOS/NativeSmoke" "$APP/Contents/Resources/Clipboard.duckpad-plugin" "$BUILD_ROOT/Consent" &
    SMOKE_PID=$!
    if ! swift native/Tests/AcceptSavePanel.swift "$SMOKE_PID" "${DUCKPAD_NATIVE_SAVE_NAME:-module.dylib}"; then
        kill "$SMOKE_PID" 2>/dev/null || true
        wait "$SMOKE_PID" 2>/dev/null || true
        exit 1
    fi
    wait "$SMOKE_PID"
    if [[ "${DUCKPAD_NATIVE_VERIFY_RELAUNCH:-0}" == "1" ]]; then
        "$APP/Contents/MacOS/NativeSmoke" "$APP/Contents/Resources/Clipboard.duckpad-plugin" "$BUILD_ROOT/Consent" verify
    fi
else
    "$APP/Contents/MacOS/NativeSmoke" "$APP/Contents/Resources/Clipboard.duckpad-plugin"
fi
