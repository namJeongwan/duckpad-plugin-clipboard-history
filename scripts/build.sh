#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_ROOT="${1:?Usage: bash scripts/build.sh /path/to/duckpad/SDK/DuckpadNative}"
SDK_ROOT="$(cd "$SDK_ROOT" && pwd)"
OUTPUT="dist/native/com.duckpad.clipboard-history.duckpad-plugin"
mkdir -p "$OUTPUT" target/native
export MACOSX_DEPLOYMENT_TARGET=13.0
ARCHITECTURE="${2:-universal}"
case "$ARCHITECTURE" in
  universal) ARCHES=(arm64 x86_64) ;;
  native) ARCHES=("$(uname -m)") ;;
  arm64|x86_64) ARCHES=("$ARCHITECTURE") ;;
  *) echo "Architecture must be universal, native, arm64, or x86_64" >&2; exit 64 ;;
esac
MODULES=()
for ARCH in "${ARCHES[@]}"; do
  if [[ "$ARCH" == arm64 ]]; then RUST_TARGET=aarch64-apple-darwin; else RUST_TARGET=x86_64-apple-darwin; fi
  ARCH_ROOT="target/native/$ARCH"
  mkdir -p "$ARCH_ROOT"
  rustc +1.91.1 --target "$RUST_TARGET" --edition 2021 --crate-type staticlib -C opt-level=2 -C panic=abort src/lib.rs -o "$ARCH_ROOT/libclipboard.a"
  swiftc -target "$ARCH-apple-macosx13.0" -swift-version 6 -O -emit-library -module-name DuckpadClipboardNative_0_2_1 \
    -I "$SDK_ROOT/include" -I native/include "$SDK_ROOT/Swift/DuckpadHost.swift" native/Sources/*.swift \
    "$ARCH_ROOT/libclipboard.a" -framework AppKit -framework Security -framework SystemConfiguration -lresolv \
    -o "$ARCH_ROOT/module.dylib"
  MODULES+=("$ARCH_ROOT/module.dylib")
done
if [[ "${#MODULES[@]}" == 1 ]]; then cp "${MODULES[0]}" "$OUTPUT/module.dylib"; else lipo -create "${MODULES[@]}" -output "$OUTPUT/module.dylib"; fi
codesign --force --sign "${DUCKPAD_PLUGIN_SIGN_IDENTITY:--}" --options runtime "$OUTPUT/module.dylib"
cp plugin.json "$OUTPUT/plugin.json"
cp native/Resources/*.strings "$OUTPUT/"
python3 - "$OUTPUT" <<'PY'
import sys,pathlib,hashlib
root=pathlib.Path(sys.argv[1]);files=sorted(p for p in root.iterdir() if p.name not in ['SHA256SUMS','SIGNATURE.ed25519'])
(root/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files))
PY
printf 'Built native package: %s\n' "$OUTPUT"
