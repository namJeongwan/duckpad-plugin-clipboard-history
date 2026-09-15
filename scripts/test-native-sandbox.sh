#!/bin/bash
set -euo pipefail
export DUCKPAD_NATIVE_VERIFY_RELAUNCH=1
export DUCKPAD_NATIVE_SAVE_NAME=Clipboard.duckpad-plugin
export DUCKPAD_NATIVE_SMOKE_SOURCE=native/Tests/SandboxConsentSmoke.swift
export DUCKPAD_NATIVE_SAVE_PANEL_SMOKE=1
exec bash "$(dirname "$0")/test-native-hardened.sh" "$@"
