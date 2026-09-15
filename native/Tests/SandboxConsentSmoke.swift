import AppKit
import Darwin

@MainActor final class ConsentProbe: NSObject, NSApplicationDelegate {
    var owner: NSWindow!
    var panel: NSSavePanel!
    var root: URL { URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) }
    var bookmarkFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("consent-" + root.deletingLastPathComponent().lastPathComponent + ".bookmark") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.last == "verify" {
            do {
                var stale = false
                let directory = try URL(resolvingBookmarkData: Data(contentsOf: bookmarkFile), options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                guard !stale, directory.startAccessingSecurityScopedResource() else { finish("Bookmark access failed", code: 1); return }
                defer { directory.stopAccessingSecurityScopedResource(); try? FileManager.default.removeItem(at: bookmarkFile) }
                try load(directory)
                finish("PASS: relaunch resolves security-scoped bookmark and loads the installed native module", code: 0)
            } catch { finish(error.localizedDescription, code: 1) }
            return
        }
        owner = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.title = "Duckpad native plugin sandbox test"
        owner.center(); owner.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel = NSSavePanel()
        panel.directoryURL = root
        panel.nameFieldStringValue = "Clipboard.duckpad-plugin"
        panel.message = "Native plugin sandbox test — temporary package only"
        panel.beginSheetModal(for: owner) { [self] response in
            guard response == .OK, let destination = panel.url else { finish("CANCELLED", code: 2); return }
            do {
                guard destination.resolvingSymlinksInPath().path == root.appendingPathComponent("Clipboard.duckpad-plugin").resolvingSymlinksInPath().path else { finish("Unexpected destination", code: 2); return }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let source = URL(fileURLWithPath: CommandLine.arguments[1])
                for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try Data(contentsOf: file).write(to: destination.appendingPathComponent(file.lastPathComponent), options: .withoutOverwriting)
                }
                try destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil).write(to: bookmarkFile)
                try load(destination)
                finish("PASS: sandboxed, hardened, system save-panel consent, native package loaded", code: 0)
            } catch { finish(error.localizedDescription, code: 1) }
        }
    }
    func load(_ directory: URL) throws {
        guard let handle = dlopen(directory.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL) else { throw NSError(domain: "NativeConsentSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: dlerror())]) }
        guard let address = dlsym(handle, "duckpad_native_abi_version"), unsafeBitCast(address, to: (@convention(c) () -> UInt32).self)() == 1 else { throw CocoaError(.executableRuntimeMismatch) }
    }
    func finish(_ message: String, code: Int32) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
        exit(code)
    }
}
@main struct SandboxConsentSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ConsentProbe()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
