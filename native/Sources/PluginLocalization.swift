import Foundation

struct LocalizationCatalog: Sendable {
    let language: String
    let directory: URL
    private let strings: [String: String]
    init(language: String, directory: URL) {
        self.language = language; self.directory = directory
        func load(_ code: String) -> [String: String] {
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("locale-\(code).strings")),
                  let table = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: String] else { return [:] }
            return table
        }
        strings = load("en").merging(load(language)) { _, translated in translated }
    }
    func text(_ key: String, arguments: [CVarArg] = []) -> String {
        let value = strings[key] ?? key
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: language), arguments: arguments)
    }
}
@MainActor enum L10n {
    static var catalog = LocalizationCatalog(language: "en", directory: URL(fileURLWithPath: "/"))
}
