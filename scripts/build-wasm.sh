#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/com.duckpad.clipboard-history.duckpad-plugin
rustc +1.91.1 --edition 2021 --crate-type cdylib --target wasm32-unknown-unknown -C opt-level=z -C panic=abort \
 -C target-feature=-bulk-memory -C link-arg=--no-entry -C link-arg=--export=duckpad_invoke \
 -C link-arg=--export=duckpad_output_pointer -C link-arg=--export=duckpad_output_length \
 -C link-arg=--export=memory -C link-arg=--initial-memory=5242880 -C link-arg=--max-memory=8388608 \
 -C link-arg=--strip-all src/lib.rs -o dist/com.duckpad.clipboard-history.duckpad-plugin/module.wasm
cp legacy/wasm-plugin.json dist/com.duckpad.clipboard-history.duckpad-plugin/plugin.json
cd dist/com.duckpad.clipboard-history.duckpad-plugin
shasum -a256 module.wasm plugin.json > SHA256SUMS
printf 'Unsigned package built. Sign SHA256SUMS with the declared publisher key before installation.\n'
