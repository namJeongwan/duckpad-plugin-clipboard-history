# Duckpad Clipboard History

Clipboard History 0.2.1 is a native Duckpad plugin. Rust implements history, retention, deduplication, pinning, search, and deletion. Swift implements AppKit UI, clipboard observation, private persistence, localization, and the Duckpad native SDK boundary. The plugin owns its UI and all eight translation catalogs; updating the panel no longer requires rebuilding Duckpad.

Requires **Duckpad 0.6.0 with host API 1.3.0 / native ABI v1**. Earlier released Duckpad versions do not support this native plugin. The release package is Universal, supporting Apple Silicon and Intel Macs.

## Build and test

Install the pinned Rust toolchain and Apple's Swift/macOS SDK, then provide the Duckpad SDK directory:

```sh
cargo test
rustup target add --toolchain 1.91.1 aarch64-apple-darwin x86_64-apple-darwin
bash scripts/build.sh /path/to/duckpad/SDK/DuckpadNative
bash scripts/test-native.sh /path/to/duckpad/SDK/DuckpadNative
swift scripts/sign.swift dist/native/com.duckpad.clipboard-history.duckpad-plugin
bash /path/to/duckpad/scripts/test_native_installer.sh dist/native/com.duckpad.clipboard-history.duckpad-plugin
```

The build defaults to Universal; pass `native` as its second argument for a local single-architecture build. The build links a Rust static library into a Swift dynamic library and ad-hoc code-signs it for local testing. Set `DUCKPAD_PLUGIN_SIGN_IDENTITY` to a production signing identity for distribution. The separate package signing script reuses the persisted `clipboard-release-1` key outside this repository, or takes an explicit private-key path. `publisher.json` contains only public metadata. Neither script creates or rotates keys.

Install the signed directory using **Plugins Admin → Install Plugin…**, it is enabled immediately with its declared capabilities. Duckpad installs the executable automatically in its managed folder through its embedded installer service. No installation-location picker is shown. Duckpad itself keeps App Sandbox enabled. Open it through **Tools → Clipboard History** or **⌥⌘V**. Native code runs in the Duckpad process; its declared capabilities are not a sandbox boundary. Disabling stops timers/tasks and removes the view. Closing only the panel keeps collection active.

## Source layout

- `src/lib.rs`: shared Rust history engine and native C memory ownership functions.
- `native/Sources/ClipboardPlugin.swift`: plugin lifecycle, polling and event sequencing.
- `native/Sources/ClipboardPanel.swift`: plugin-owned AppKit UI.
- `native/Sources/ClipboardEngine.swift`: worker and private state persistence.
- `native/Sources/NativeEntry.swift`: versioned C entry points.
- `native/Resources/`: eight plugin-owned localization catalogs.
- `native/Tests/NativeSmoke.swift`: loads the actual dynamic module, using an isolated pasteboard and temporary storage.
- `legacy/wasm-plugin.json`, `scripts/build-wasm.sh`: retained 0.1.2 WASM compatibility build.

The native plugin keeps the same publisher/command storage identity and state format, preserving unexpired history and pins from 0.1.x. Preexisting clipboard contents are not imported on activation. Retention is 1, 3, or 7 days; pinned entries expire too. History persists across restart. Sequential paste stops at the final visible result. Delayed insertion uses a host token bound to the editor state at the user's request.

Host SDK documentation: `duckpad/docs/plugins/native-sdk.md` and `duckpad/SDK/DuckpadNative/include/DuckpadNative.h`. The native API is currently a development SDK, not a published stable API or a full Notepad++ API equivalent. The flat signed package format remains. Duckpad detects published catalog releases and installs them when Update is clicked. Native updates apply on the next app launch without interrupting the current plugin; history remains separate. No separate Duckpad permission review is required; macOS may ask when protected system resources are accessed. Uninstall UI is not implemented yet.

Catalog: https://github.com/namJeongwan/duckpad-plugins

## Release archive

After signing, create the download archive with `python3 scripts/package-archive.py dist/native/com.duckpad.clipboard-history.duckpad-plugin /absolute/path/clipboard-history-0.2.1.zip`. The script prints its SHA-256 for the catalog release entry. Publish the archive as a GitHub release asset before adding that release to the catalog.

When keyboard focus is inside Clipboard History, Command-W closes only its panel using the host close callback. This also works from search, preview, and panel buttons. With focus in the document editor, Duckpad keeps its normal document-close behavior. Closing the panel keeps history collection active.
