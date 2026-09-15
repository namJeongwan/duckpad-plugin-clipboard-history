#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_ROOT="${1:?Usage: bash scripts/test-native.sh /path/to/duckpad/SDK/DuckpadNative}"
mkdir -p target/native
swiftc -swift-version 6 -parse-as-library -I "$SDK_ROOT/include" native/Tests/NativeSmoke.swift -o target/native/smoke
./target/native/smoke "$(pwd)/dist/native/com.duckpad.clipboard-history.duckpad-plugin"
