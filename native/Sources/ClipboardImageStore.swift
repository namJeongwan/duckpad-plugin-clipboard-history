import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct ClipboardImageReference: Equatable, Sendable {
    let digest: String
    let width: Int
    let height: Int
    let byteCount: Int
    var descriptor: String { "\(digest):\(width):\(height):\(byteCount)" }
    init(_ descriptor: String) throws {
        let parts = descriptor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].count == 64,
              parts[0].allSatisfy({ "0123456789abcdef".contains($0) }),
              let w = Int(parts[1]), let h = Int(parts[2]), let size = Int(parts[3]),
              w > 0, h > 0, w <= 64_000_000, h <= 64_000_000, w * h <= 64_000_000,
              size > 0, size <= ClipboardImageStore.maximumBytes else { throw HistoryError.invalidResult("image reference") }
        digest = String(parts[0]); width = w; height = h; byteCount = size
    }
}

/// Image work runs on the history actor; only bounded PNG data reaches AppKit.
struct ClipboardImageStore {
    static let maximumBytes = 32 * 1024 * 1024
    let directory: URL
    init(root: URL) { directory = root.appendingPathComponent("Images", isDirectory: true) }
    static func readCopiedFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw HistoryError.limitExceeded("clipboard image file") }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else { throw HistoryError.limitExceeded("clipboard image file") }
        return data
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
    }
    private func decode(_ data: Data, maximumDimension: Int? = nil) throws -> CGImage {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 64_000_000, h <= 64_000_000, w * h <= 64_000_000 else { throw HistoryError.invalidResult("clipboard image") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension ?? max(w, h)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw HistoryError.invalidResult("image decode") }
        return image
    }
    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw HistoryError.invalidResult("PNG encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= Self.maximumBytes else { throw HistoryError.limitExceeded("clipboard image") }
        return data as Data
    }
    private func write(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func capture(_ data: Data, sourceFile: URL? = nil) throws -> ClipboardImageReference {
        try prepare()
        let image = try decode(data)
        let original = try png(image)
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let ref = try ClipboardImageReference("\(hash):\(image.width):\(image.height):\(original.count)")
        try write(original, name: hash + ".png")
        try write(png(decode(original, maximumDimension: 64)), name: hash + ".thumb.png")
        if let sourceFile {
            try write(JSONEncoder().encode(sourceFile.path), name: hash + ".source.json")
        }
        return ref
    }
    private func read(_ name: String, limit: Int) throws -> Data {
        try prepare()
        let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { throw CocoaError(.fileReadCorruptFile) }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
    }
    func original(_ ref: ClipboardImageReference) throws -> Data {
        let data = try read(ref.digest + ".png", limit: Self.maximumBytes)
        guard data.count == ref.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == ref.digest else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    func sourcePath(_ ref: ClipboardImageReference) -> String? {
        guard let data = try? read(ref.digest + ".source.json", limit: 64 * 1024) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
    func preview(_ ref: ClipboardImageReference) throws -> Data { try png(decode(original(ref), maximumDimension: 1200)) }
    func thumbnail(_ ref: ClipboardImageReference) throws -> Data {
        if let data = try? read(ref.digest + ".thumb.png", limit: 256 * 1024) { return data }
        let data = try png(decode(original(ref), maximumDimension: 64))
        try write(data, name: ref.digest + ".thumb.png")
        return data
    }
    func retain(_ references: [ClipboardImageReference]) throws {
        try prepare()
        let keep = Set(references.flatMap { [$0.digest + ".png", $0.digest + ".thumb.png", $0.digest + ".source.json"] })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard !keep.contains(url.lastPathComponent),
                  url.lastPathComponent.range(of: "^[0-9a-f]{64}((\\.thumb)?\\.png|\\.source\\.json)$", options: .regularExpression) != nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
