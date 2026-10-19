import AppKit

@main struct LocalizedImageSearch {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-localized-image-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 255, count: 16)
        let png = bitmap.representation(using: .png, properties: [:])!
        let engine = ClipboardEngine(directory: root)
        _ = try await engine.process(event: "capture", payload: "ordinary text 이미지", query: "")
        _ = try await engine.process(event: "capture-image", payload: "", query: "", image: png)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        for language in ["en", "ko", "ja", "zh-Hans", "de", "fr", "it", "pt-BR"] {
            let catalog = LocalizationCatalog(language: language, directory: resources)
            let label = catalog.text("Image")
            let found = try await engine.process(event: "query", payload: "", query: label, imageKindLabel: label)
            precondition(found.rows.filter { $0.image != nil }.count == 1, "Missing localized image match: \(language)")
            let partial = try await engine.process(event: "query", payload: "", query: String(label.prefix(1)), imageKindLabel: label)
            precondition(partial.rows.filter { $0.image != nil }.count == 1)
            let none = try await engine.process(event: "query", payload: "", query: "not-a-match-xyz", imageKindLabel: label)
            precondition(none.rows.isEmpty)
        }
        let text = try await engine.process(event: "query", payload: "", query: "ordinary", imageKindLabel: "이미지")
        precondition(text.rows.count == 1 && text.rows[0].image == nil)
        let korean = try await engine.process(event: "query", payload: "", query: "이미지", imageKindLabel: "이미지")
        precondition(korean.rows.count == 2, "Existing text matching must remain available")
        let english = try await engine.process(event: "query", payload: "", query: "IMAGE", imageKindLabel: "이미지")
        precondition(english.rows.count == 1 && english.rows[0].image != nil)
        let recovered = ClipboardEngine(directory: root)
        let result = try await recovered.process(event: "query", payload: "", query: "画像", imageKindLabel: "画像")
        precondition(result.rows.count == 1 && result.rows[0].image != nil)
        print("PASS: localized image search in all eight languages, partial queries, English alias, text matching, and persisted history")
    }
}
