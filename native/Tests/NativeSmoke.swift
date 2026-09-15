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
        guard let handle = dlopen(package.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
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
        stop(instance)
        let before = try Data(contentsOf: root.appendingPathComponent("state.bin"))
        pasteboard.clearContents(); pasteboard.setString("must not be captured", forType: .string)
        try await Task.sleep(for: .milliseconds(700))
        let after = try Data(contentsOf: root.appendingPathComponent("state.bin"))
        precondition(before == after)
        print("PASS: native ABI, plugin-owned AppKit UI, legacy migration, clipboard capture, search, sequential paste, delete selection, preview, live i18n, focus-scoped Command-W, close callback, disable stops capture")
    }
}
