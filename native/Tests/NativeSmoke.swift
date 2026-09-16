import AppKit
import Darwin
import DuckpadNativeABI

@MainActor enum State {
    static var pasted: [String] = []
    static var closed = false
}
@main struct NativeSmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let sourcePackage = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-native-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("VerifiedModule")
        // Match the host's verified-byte materialization, not copyItem's xattr copying.
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for source in try FileManager.default.contentsOfDirectory(at: sourcePackage, includingPropertiesForKeys: nil) {
            try Data(contentsOf: source).write(to: package.appendingPathComponent(source.lastPathComponent), options: .withoutOverwriting)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: package.appendingPathComponent("module.dylib").path)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        var legacy = Data()
        func u32(_ value: UInt32) { var x = value.littleEndian; withUnsafeBytes(of: &x) { legacy.append(contentsOf: $0) } }
        func u64(_ value: UInt64) { var x = value.littleEndian; withUnsafeBytes(of: &x) { legacy.append(contentsOf: $0) } }
        func text(_ value: String) { u32(UInt32(value.utf8.count)); legacy.append(contentsOf: value.utf8) }
        u32(1); u64(2); u32(2)
        u64(1); u32(1); text("pinned legacy")
        u64(2); u32(0); text("legacy second")
        try legacy.write(to: root.appendingPathComponent("state.bin"))
        // A sandboxed harness loads its prebuilt bundle resource, like managed
        // installation. Executable bytes created by the sandbox cannot be mapped.
        let moduleRoot = ProcessInfo.processInfo.environment["DUCKPAD_SMOKE_BUNDLED_MODULE"] == "1" ? sourcePackage : package
        guard let handle = dlopen(moduleRoot.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
        typealias Create = @convention(c) (UnsafePointer<DuckpadHostV1>?, UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?
        typealias View = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        typealias Action = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias Language = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
        func symbol<T>(_ name: String, _ type: T.Type) -> T { unsafeBitCast(dlsym(handle, name)!, to: type) }
        let create = symbol("duckpad_native_create", Create.self), view = symbol("duckpad_native_view", View.self)
        let stop = symbol("duckpad_native_deactivate", Action.self), destroy = symbol("duckpad_native_destroy", Action.self)
        let language = symbol("duckpad_native_set_language", Language.self)
        var api = DuckpadHostV1(); api.abi_version = 1; api.struct_size = UInt32(MemoryLayout<DuckpadHostV1>.size)
        api.prepare_insert = { _ in 1 }
        api.insert_text = { _, _, bytes, count in
            let text = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            return MainActor.assumeIsolated { State.pasted.append(text); return 1 }
        }
        api.close_panel = { _ in MainActor.assumeIsolated { State.closed = true } }
        let config = try JSONSerialization.data(withJSONObject: ["resourceDirectory": package.path, "storageDirectory": root.path, "language": "ja", "testPasteboard": pasteboard.name.rawValue])
        let instance = config.withUnsafeBytes { create(&api, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }!
        defer { stop(instance); destroy(instance) }
        let panel = Unmanaged<NSView>.fromOpaque(view(instance)!).takeUnretainedValue()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let all = descendants(panel)
        let table = all.compactMap { $0 as? NSTableView }.first!
        let search = all.compactMap { $0 as? NSSearchField }.first!
        func button(_ selector: String) -> NSButton { all.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString(selector) }! }
        func wait(_ label: String, _ check: () -> Bool) async throws {
            for _ in 0..<150 { if check() { return }; try await Task.sleep(for: .milliseconds(20)) }
            fatalError("Timed out: \(label)")
        }
        try await wait("legacy migration") { table.numberOfRows == 2 }
        precondition(search.placeholderString == "クリップボード履歴を検索")
        let migrated = try Data(contentsOf: root.appendingPathComponent("state.bin"))
        precondition(migrated.first == 2)
        for (text, count) in [("capture first", 3), ("capture second", 4)] {
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            try await wait("capture") { table.numberOfRows == count }
        }
        search.stringValue = "capture"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await wait("search") { table.numberOfRows == 2 }
        let next = button("selectNext")
        _ = next.sendAction(next.action, to: next.target)
        try await wait("first sequential paste") { State.pasted.count == 1 && table.selectedRow == 1 }
        _ = next.sendAction(next.action, to: next.target)
        try await wait("second sequential paste") { State.pasted.count == 2 && !next.isEnabled }
        precondition(State.pasted == ["capture second", "capture first"])
        let delete = button("deleteItem"); _ = delete.sendAction(delete.action, to: delete.target)
        try await wait("delete selection") { table.numberOfRows == 1 && table.selectedRow == 0 }
        let preview = all.compactMap { $0 as? NSTextView }.first!
        try await wait("preview") { preview.string == "capture second" }
        let pastedBeforeReopen = State.pasted.count
        let paste = button("selectItem")
        _ = paste.sendAction(paste.action, to: paste.target)
        _ = view(instance) // A pending paste must not cross into a new presentation.
        try await wait("reopened preview") { preview.string == "capture second" }
        precondition(State.pasted.count == pastedBeforeReopen)
        "ko".withCString { language(instance, $0) }
        precondition(search.placeholderString == "클립보드 기록 검색")
        // Real bitmap capture, thumbnail and preview rendering, roundtrip copy,
        // deduplication, search-safe blob retention, restart, and deletion cleanup.
        search.stringValue = ""
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await wait("unfiltered") { table.numberOfRows == 3 }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1550, pixelsHigh: 843,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<843 { for x in 0..<1550 {
            bitmap.setColor(x < 775 ? NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1) : NSColor(deviceRed: 1, green: 0.5, blue: 0.1, alpha: 1), atX: x, y: y)
        } }
        let windowSizeBeforeImage = window.frame.size
        let png = bitmap.representation(using: .png, properties: [:])!
        // Finder supplies a file URL and often a filename string, not bitmap data.
        let copiedFile = root.appendingPathComponent("duckpad-tiff.png")
        try png.write(to: copiedFile)
        let finderItem = NSPasteboardItem()
        finderItem.setString(copiedFile.absoluteString, forType: .fileURL)
        finderItem.setString(copiedFile.lastPathComponent, forType: .string)
        pasteboard.clearContents(); pasteboard.writeObjects([finderItem])
        try await wait("Finder image capture") { table.numberOfRows == 4 }
        search.stringValue = "image"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        let imagePreview = all.compactMap { $0 as? NSImageView }.first { $0.accessibilityIdentifier() == "duckpad.plugin.list.image-preview" }!
        try await wait("image preview") { table.numberOfRows == 1 && imagePreview.image != nil && !imagePreview.isHidden }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        precondition(window.frame.size == windowSizeBeforeImage, "Image preview must not enlarge the window")
        precondition(panel.fittingSize.height <= windowSizeBeforeImage.height, "Image intrinsic size must not become a minimum panel height")
        precondition(imagePreview.bounds.height <= panel.bounds.height * 0.26)
        precondition(imagePreview.image!.size.width <= 1200)
        window.setContentSize(NSSize(width: 360, height: 500))
        panel.layoutSubtreeIfNeeded()
        precondition(panel.bounds.height <= 500.5, "Image panel must shrink again")
        precondition(imagePreview.bounds.height <= 130)
        precondition(paste.convert(paste.bounds, to: panel).minY >= 0, "Actions must remain visible")
        window.setContentSize(NSSize(width: 500, height: 650))
        panel.layoutSubtreeIfNeeded()
        try FileManager.default.removeItem(at: copiedFile) // History owns the image snapshot.
        precondition(paste.title == "이미지 복사")
        window.contentView?.layoutSubtreeIfNeeded()
        let rowCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        precondition(descendants(rowCell).compactMap { $0 as? NSImageView }.contains { $0.image != nil })
        if let snapshotPath = ProcessInfo.processInfo.environment["DUCKPAD_IMAGE_SNAPSHOT"] {
            let snapshot = panel.bitmapImageRepForCachingDisplay(in: panel.bounds)!
            panel.cacheDisplay(in: panel.bounds, to: snapshot)
            try snapshot.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: snapshotPath))
        }
        // Host menu close detaches the panel without calling its own onClose.
        let changeBeforeDetach = pasteboard.changeCount
        _ = paste.sendAction(paste.action, to: paste.target)
        window.contentView = nil
        search.stringValue = "no-match-after-detach"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        // Query is queued after the copy, so this observes completed image work.
        try await wait("detached image work drained") { table.numberOfRows == 0 }
        precondition(pasteboard.changeCount == changeBeforeDetach, "Detached panel must cancel a pending image copy")
        search.stringValue = "image"
        window.contentView = panel
        _ = view(instance)
        try await wait("image preview after reopen") { paste.isEnabled && imagePreview.image != nil }
        let imageCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
        precondition(imageCell.textField?.stringValue == "duckpad-tiff.png")
        precondition(imageCell.toolTip == copiedFile.path)
        search.stringValue = "duckpad-tiff"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await wait("filename search") { table.numberOfRows == 1 && imagePreview.image != nil }
        let pastedCount = State.pasted.count
        let changeBeforeCopy = pasteboard.changeCount
        _ = table.sendAction(table.doubleAction, to: table.target)
        try await wait("double-click copies image") { paste.isEnabled && pasteboard.changeCount != changeBeforeCopy }
        precondition(State.pasted.count == pastedCount, "Image metadata must never enter the editor")
        let copied = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        precondition(copied.pixelsWide == 1550 && copied.pixelsHigh == 843)
        precondition(copied.colorAt(x: 10, y: 10)!.blueComponent > 0.5)
        let imageState = try Data(contentsOf: root.appendingPathComponent("state.bin"))
        precondition(imageState.first == 3)
        pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
        try await Task.sleep(for: .milliseconds(700))
        precondition(table.numberOfRows == 1, "Re-copy must deduplicate")
        search.stringValue = "capture"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await wait("text filter with hidden image") { table.numberOfRows == 1 && preview.string == "capture second" }
        let imageDirectory = root.appendingPathComponent("Images")
        let filesBeforeDelete = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)
        precondition(filesBeforeDelete.count == 3)
        search.stringValue = "image"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await wait("restore image preview") { imagePreview.image != nil }
        search.stringValue = "capture"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await wait("text preview before focus tests") { preview.string == "capture second" }
        func closeKey(_ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        }
        // Exercise AppKit's window-to-view shortcut dispatch, including search's
        // shared field editor and every other focusable part of the plugin UI.
        for target: NSView in [table, search, preview, button("selectItem"), panel] {
            precondition(window.makeFirstResponder(target))
            State.closed = false
            precondition(window.performKeyEquivalent(with: closeKey()), "Focused Clipboard must consume Command-W")
            precondition(State.closed, "Command-W must use the host close callback")
        }
        State.closed = false
        precondition(!window.performKeyEquivalent(with: closeKey([.command, .shift])))
        precondition(!window.performKeyEquivalent(with: closeKey(.control)))
        precondition(!State.closed)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let container = NSView(frame: window.contentView!.frame)
        window.contentView = container; container.addSubview(panel); container.addSubview(editor)
        precondition(window.makeFirstResponder(editor))
        precondition(!window.performKeyEquivalent(with: closeKey()), "Editor Command-W must reach the host")
        precondition(!State.closed)
        panel.removeFromSuperview()
        precondition(!panel.performKeyEquivalent(with: closeKey()), "Detached panel must not handle shortcuts")
        window.contentView = panel
        let close = button("close"); _ = close.sendAction(close.action, to: close.target)
        precondition(State.closed)
        // A second inactive test instance reads the persisted image state.
        stop(instance)
        let restored = config.withUnsafeBytes { create(&api, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }!
        let restoredPanel = Unmanaged<NSView>.fromOpaque(view(restored)!).takeUnretainedValue()
        let restoredViews = descendants(restoredPanel)
        let restoredTable = restoredViews.compactMap { $0 as? NSTableView }.first!
        let restoredSearch = restoredViews.compactMap { $0 as? NSSearchField }.first!
        try await wait("image persistence") { restoredTable.numberOfRows == 4 }
        restoredSearch.stringValue = "image"
        restoredSearch.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: restoredSearch))
        let restoredImage = restoredViews.compactMap { $0 as? NSImageView }.first { $0.accessibilityIdentifier() == "duckpad.plugin.list.image-preview" }!
        try await wait("persisted image rendering") { restoredImage.image != nil }
        let restoredCell = restoredTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
        precondition(restoredCell.textField?.stringValue == "duckpad-tiff.png", "File labels survive restart")
        let restoredDelete = restoredViews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("deleteItem") }!
        _ = restoredDelete.sendAction(restoredDelete.action, to: restoredDelete.target)
        try await wait("image deletion") { restoredTable.numberOfRows == 0 }
        let filesAfterDelete = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)
        precondition(filesAfterDelete.isEmpty)
        let tiffFile = root.appendingPathComponent("copied.TIFF")
        let jpegFile = root.appendingPathComponent("copied.jpeg")
        let invalidFile = root.appendingPathComponent("broken.png")
        try bitmap.representation(using: .tiff, properties: [:])!.write(to: tiffFile)
        try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: jpegFile)
        try Data("not an image".utf8).write(to: invalidFile)
        pasteboard.clearContents()
        pasteboard.writeObjects([invalidFile as NSURL, tiffFile as NSURL, jpegFile as NSURL])
        try await wait("multiple Finder files after corrupt file") { restoredTable.numberOfRows == 2 && restoredImage.image != nil }
        for remaining in [1, 0] {
            _ = restoredDelete.sendAction(restoredDelete.action, to: restoredDelete.target)
            try await wait("delete copied file image") { restoredTable.numberOfRows == remaining }
        }
        let filesAfterBatch = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)
        precondition(filesAfterBatch.isEmpty)
        stop(restored); destroy(restored)
        stop(instance)
        let before = try Data(contentsOf: root.appendingPathComponent("state.bin"))
        pasteboard.clearContents(); pasteboard.setString("must not be captured", forType: .string)
        try await Task.sleep(for: .milliseconds(700))
        let after = try Data(contentsOf: root.appendingPathComponent("state.bin"))
        precondition(before == after)
        print("PASS: image capture, thumbnails, rendered preview, PNG copy, dedup, persistence, blob cleanup, native ABI, plugin-owned AppKit UI, legacy migration, clipboard capture, search, sequential paste, delete selection, preview, live i18n, focus-scoped Command-W, close callback, disable stops capture")
    }
}
