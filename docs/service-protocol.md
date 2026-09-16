> In native 0.2.0 this binary protocol is internal to the plugin’s Swift/Rust boundary. It remains the host wire protocol for legacy WASM 0.1.x. Native host integration uses DuckpadNative.h.

# List service protocol 2

A service command has `inputScope: service` and host API minimum 1.2.0. The existing zero-import `duckpad-wasm-1` exports receive binary values. The runtime returns an opaque `serviceOutput`, never editor edits. Host document commands continue to use UTF-8 transforms unchanged.

All integers are unsigned little-endian. A blob is a UInt32 length followed by those bytes; a string is a UTF-8 blob. The host validates every length and rejects trailing bytes, duplicate row IDs, invalid flags, and invalid UTF-8.

Request: UInt32 version (2), blob previous state, string event, string payload, string search query, UInt64 current Unix timestamp in seconds. The host supplies the clock; the zero-import guest does not read system time.

Response: UInt32 version (2), blob new state, UInt32 row count, rows, string selected text, UInt32 retention days (1, 3, or 7). Each row contains string ID, string title, UInt32 pinned flag (0 or 1). Text is returned for `select` and read-only `preview` events. Only `select` may paste into the editor; preview never changes the clipboard or document.

Events: `capture` adds payload text; `query` lists matches; `pin`, `delete`, `select`, and `preview` use an opaque row ID as payload; `clear` clears all entries; `retention` sets payload to 1, 3, or 7 days and immediately removes expired entries. Queries are case-insensitive. Clipboard content is preserved verbatim; display labels may be shortened. The plugin keeps up to 200 entries within a 512 KiB state budget, evicting the oldest unpinned items by count and bytes. Individual items are limited to 256 KiB; oversized items are skipped without evicting existing entries. Host search queries are limited to 16 KiB so framing, state, and a new item fit the runtime request limit. When all entries are pinned, new items are ignored until space is freed. This text-only version does not retain images.

State is private, versioned opaque plugin data. Duckpad stores it by plugin identity, publisher fingerprint, and service command identity; changing repository layout does not change identity. The module receives no filesystem paths and cannot access another plugin's data. Disabling the plugin stops events and rejects outstanding effects.

WASM memory and per-invocation input/output/time limits remain enforced by the existing host. A failed invocation must not replace the previous stored state.

## Retention and paste behavior

Default retention is seven days; one-day and three-day choices are also available. Pinned entries expire too. Expiration runs before every event (including select), and the host sends a query at least once per minute while collection is active. Expired data is removed from persisted state at that point. While Duckpad is closed or the plugin is disabled, it cannot perform disk cleanup; the next activation checks expiry before returning content. Restarting the app or computer does not clear unexpired history. Copying identical text again refreshes its age; selecting or pasting it does not. Shortening retention deletes expired records immediately and lengthening it cannot recover them.

State v1 is migrated once, retaining text and pin state; since old records have no timestamp their age starts at migration. State v2 persists the retention setting and each last-copy timestamp.

The native dock offers separate Paste and Paste Next buttons. Paste Next starts at the selected row in the current filtered, pinned-first list. After validated insertion it selects the next row, and stops at the end without wrapping. Choosing another row or changing the search resets that stopping point. Each insertion uses the active editor target captured for that request. Failed or cancelled insertion does not advance. Host clipboard writes from these actions do not reorder the history. Return remains normal Paste only when list/search has focus.

The native preview displays the full selected text with original whitespace and line breaks. Preview requests coalesce when selection changes quickly, and the host checks presentation, row identity, and search query before displaying their results. Closing the dock clears preview content. Native table cells vertically center the label within the selection background.

## Native image extension: protocol and state v3

Native 0.3.2 sends request version 3 with the same request field layout. The new
`capture-image` event receives `sha256:width:height:pngByteCount` as its payload;
image bytes never enter the Rust state or wire message. Swift validates and
normalizes bitmap/file-URL captures to PNG on the history actor first.

Response v3 appends an image descriptor (empty for text) to every row. After the
selected text and retention fields it appends the selected image descriptor,
then a UInt32 live-image count and that many descriptors. The live reference set
includes images excluded by search. Image selection returns no editor text.
Versions 1/2 still receive v2 responses with image rows excluded.

State v3 adds a UInt32 content-kind flag before each entry's text payload; image
entries store descriptors there. Text-only states continue to encode v2, and
existing full-size v2 histories remain intact when queried. State v1/v2 migration
preserves unexpired text and pins. Older native releases cannot read v3 state.

Swift stores full PNGs, bounded thumbnails, and optional source-path JSON beside
one another in the private Images directory, keyed by image digest. File capture
labels use the filename and expose the full path as a tooltip. Path matches are
merged with Rust's full-text matches while retaining row order. The state is
persisted before unreferenced image files and metadata are deleted.

Image preview never changes the clipboard. Double-click, Return, Copy Image and
Copy Next restore PNG data to the pasteboard, without sending image metadata to
the document editor. A detached/hidden panel or replaced presentation cancels a
pending copy. Source files may be moved/deleted after capture; history owns its
snapshot. PNG normalization does not preserve original encoding or container
metadata. Images are bounded to 32 MiB and 64 million pixels each, with a 256 MiB
aggregate image budget; normal history count, retention and pin rules apply.
