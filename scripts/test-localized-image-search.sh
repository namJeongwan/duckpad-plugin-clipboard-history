#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-localizations.py
mkdir -p target/native
rustc +1.91.1 --edition 2021 --crate-type staticlib -C opt-level=2 -C panic=abort src/lib.rs -o target/native/libclipboard-i18n.a
swiftc -swift-version 6 -parse-as-library -I native/include \
  native/Sources/ClipboardEngine.swift native/Sources/ClipboardImageStore.swift \
  native/Sources/HistoryProtocol.swift native/Sources/PluginLocalization.swift \
  native/Tests/LocalizedImageSearch.swift target/native/libclipboard-i18n.a \
  -framework AppKit -framework Security -framework SystemConfiguration -lresolv \
  -o target/native/localized-image-search
target/native/localized-image-search "$(pwd)/native/Resources"
