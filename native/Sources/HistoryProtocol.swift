import Foundation
public struct ClipboardRow: Equatable, Sendable {
    public let id: String
    public let title: String
    public let pinned: Bool
}

/// Version 2 value protocol shared with separately built service plugins.
/// Integers are little-endian UInt32; strings/blobs have a UInt32 byte length.
public enum ExtensionListProtocol {
    public static let maximumStateBytes = 512 * 1_024
    public static let maximumPayloadBytes = 256 * 1_024
    public static let maximumQueryBytes = 16 * 1_024
    public struct Response: Equatable, Sendable {
        public let state: Data
        public let rows: [ClipboardRow]
        public let selectedText: String
        public let retentionDays: Int
    }
    public static func request(state: Data, event: String, payload: String = "", query: String = "", now: Date = Date()) throws -> Data {
        guard state.count <= maximumStateBytes, payload.utf8.count <= maximumPayloadBytes,
              query.utf8.count <= maximumQueryBytes, event.utf8.count <= 32 else {
            throw HistoryError.limitExceeded("list service field")
        }
        var data = Data(); append(2, to: &data)
        for value in [state, Data(event.utf8), Data(payload.utf8), Data(query.utf8)] {
            append(UInt32(clamping: value.count), to: &data); data.append(value)
        }
        let seconds = now.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) else { throw HistoryError.invalidResult("service clock") }
        var timestamp = UInt64(seconds).littleEndian
        withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
        return data
    }
    public static func response(_ data: Data) throws -> Response {
        var reader = Reader(data: data)
        let version = try reader.integer()
        guard version == 1 || version == 2 else { throw HistoryError.unsupportedAPI }
        let state = try reader.blob()
        guard state.count <= maximumStateBytes else { throw HistoryError.limitExceeded("list service state") }
        let count = try reader.integer()
        guard count <= 10_000 else { throw HistoryError.limitExceeded("list rows") }
        var rows: [ClipboardRow] = []; var ids: Set<String> = []
        for _ in 0..<count {
            let id = try reader.string(), title = try reader.string(), pinned = try reader.integer()
            guard !id.isEmpty, ids.insert(id).inserted, pinned <= 1 else { throw HistoryError.invalidResult("list row") }
            rows.append(ClipboardRow(id: id, title: title, pinned: pinned == 1))
        }
        let text = try reader.string()
        let retentionDays = version == 2 ? Int(try reader.integer()) : 7
        guard [1, 3, 7].contains(retentionDays) else { throw HistoryError.invalidResult("retention period") }
        guard reader.offset == data.count else { throw HistoryError.invalidResult("trailing service data") }
        return Response(state: state, rows: rows, selectedText: text, retentionDays: retentionDays)
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private struct Reader {
        let data: Data; var offset = 0
        mutating func integer() throws -> UInt32 {
            guard data.count - offset >= 4 else { throw HistoryError.invalidResult("truncated service data") }
            defer { offset += 4 }
            return data[offset..<offset+4].enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        }
        mutating func blob() throws -> Data {
            let count = Int(try integer())
            guard count <= data.count - offset else { throw HistoryError.invalidResult("invalid service field") }
            defer { offset += count }; return data.subdata(in: offset..<offset+count)
        }
        mutating func string() throws -> String {
            guard let text = String(data: try blob(), encoding: .utf8) else { throw HistoryError.invalidResult("service UTF-8") }
            return text
        }
    }
}


enum HistoryError: Error { case limitExceeded(String), invalidResult(String), unsupportedAPI }
