import Foundation
import Darwin
import ClipboardCore

actor ClipboardEngine {
    private let directory: URL
    private var state: Data?
    init(directory: URL) { self.directory = directory }
    func process(event: String, payload: String, query: String, image: Data? = nil, imageFile: URL? = nil) throws -> ExtensionListProtocol.Response {
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
        let images = ClipboardImageStore(root: directory)
        let imageData = try imageFile.map { try ClipboardImageStore.readCopiedFile($0) } ?? image
        let payload = try imageData.map { try images.capture($0, sourceFile: imageFile).descriptor } ?? payload
        let input = try ExtensionListProtocol.request(state: state ?? Data(), event: event, payload: payload, query: query)
        var result = try invoke(input)
        // The Rust engine searches complete text entries. Merge filename/path
        // matches using all rows, preserving its pinned/chronological ordering.
        let matchingTextIDs = Set(result.rows.map(\.id))
        if !query.isEmpty {
            result.rows = try invoke(ExtensionListProtocol.request(state: result.state, event: "query")).rows
        }
        for index in result.rows.indices {
            if let image = result.rows[index].image { result.rows[index].sourcePath = images.sourcePath(image) }
        }
        if !query.isEmpty {
            result.rows = result.rows.filter { matchingTextIDs.contains($0.id) || $0.sourcePath?.localizedCaseInsensitiveContains(query) == true }
        }
        try Task.checkCancellation()
        if result.state != state {
            let file = directory.appendingPathComponent("state.bin")
            try result.state.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            state = result.state
        }
        // Persist the reference set before removing expired/deleted blobs.
        try images.retain(result.liveImages)
        for row in result.rows {
            if let ref = row.image, let thumbnail = try? images.thumbnail(ref) { result.thumbnails[ref.digest] = thumbnail }
        }
        if let selected = result.selectedImage {
            result.imageData = try event == "preview" ? images.preview(selected) : images.original(selected)
        }
        return result
    }
    private func invoke(_ input: Data) throws -> ExtensionListProtocol.Response {
        let output: Data = try input.withUnsafeBytes { bytes in
            var length = 0
            guard let pointer = clipboard_native_process(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &length) else { throw HistoryError.invalidResult("history engine") }
            defer { clipboard_native_free(pointer, length) }
            return Data(bytes: pointer, count: length)
        }
        return try ExtensionListProtocol.response(output)
    }

}
