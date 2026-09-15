import Foundation
import Darwin
import ClipboardCore

actor ClipboardEngine {
    private let directory: URL
    private var state: Data?
    init(directory: URL) { self.directory = directory }
    func process(event: String, payload: String, query: String) throws -> ExtensionListProtocol.Response {
        try Task.checkCancellation()
        if state == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("state.bin")
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            if fd >= 0 {
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_size >= 0, info.st_size <= ExtensionListProtocol.maximumStateBytes else { throw CocoaError(.fileReadCorruptFile) }
                state = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            } else if errno == ENOENT { state = Data() }
            else { throw CocoaError(.fileReadNoPermission) }
        }
        let input = try ExtensionListProtocol.request(state: state ?? Data(), event: event, payload: payload, query: query)
        let output: Data = try input.withUnsafeBytes { bytes in
            var length = 0
            guard let pointer = clipboard_native_process(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &length) else { throw HistoryError.invalidResult("history engine") }
            defer { clipboard_native_free(pointer, length) }
            return Data(bytes: pointer, count: length)
        }
        let result = try ExtensionListProtocol.response(output)
        try Task.checkCancellation()
        if result.state != state {
            let file = directory.appendingPathComponent("state.bin")
            try result.state.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            state = result.state
        }
        return result
    }
}
