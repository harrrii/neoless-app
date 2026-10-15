import Foundation
import NeolessCloud
import NeolessCore

/// One dictation as history.json keeps it: the result plus what the history list and the next steps need.
/// Times are written with milliseconds (`HubJSON`), so a `createdAt` reads back exactly as the device got it.
public struct HubHistoryEntry: Codable, Equatable, Sendable {
    public var result: DictationResult
    public var appName: String?
    public var bundleID: String?
    public var client: HubClientKind?
    public var clientVersion: String?
    public var durationSeconds: Double?
    /// The user changed the text afterwards (`…/edit`).
    public var edited: Bool

    public init(result: DictationResult, appName: String? = nil, bundleID: String? = nil, client: HubClientKind? = nil,
                clientVersion: String? = nil, durationSeconds: Double? = nil, edited: Bool = false) {
        self.result = result; self.appName = appName; self.bundleID = bundleID; self.client = client
        self.clientVersion = clientVersion; self.durationSeconds = durationSeconds; self.edited = edited
    }

    public var item: HistoryItem { HistoryItem(result: result, appName: appName, client: client, edited: edited) }

    private enum CodingKeys: String, CodingKey {
        case id, clientRecordingID, raw, text, mode, polished, fallback, recognizer, timings, createdAt
        case appName, bundleID, client, clientVersion, durationSeconds, edited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let createdText = try c.decode(String.self, forKey: .createdAt)
        guard let createdAt = HubJSON.date(from: createdText) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: c, debugDescription: "不是 ISO 8601 时间")
        }
        result = DictationResult(
            id: try c.decode(UUID.self, forKey: .id),
            clientRecordingID: try c.decode(UUID.self, forKey: .clientRecordingID),
            raw: try c.decode(String.self, forKey: .raw),
            text: try c.decode(String.self, forKey: .text),
            mode: try c.decode(DictationMode.self, forKey: .mode),
            polished: try c.decode(Bool.self, forKey: .polished),
            fallback: try c.decodeIfPresent(HubFallback.self, forKey: .fallback),
            recognizer: try c.decode(HubRecognizer.self, forKey: .recognizer),
            timings: try c.decodeIfPresent(HubTimings.self, forKey: .timings) ?? HubTimings(),
            createdAt: createdAt)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        client = try c.decodeIfPresent(HubClientKind.self, forKey: .client)
        clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(result.id, forKey: .id)
        try c.encode(result.clientRecordingID, forKey: .clientRecordingID)
        try c.encode(result.raw, forKey: .raw)
        try c.encode(result.text, forKey: .text)
        try c.encode(result.mode, forKey: .mode)
        try c.encode(result.polished, forKey: .polished)
        try c.encodeIfPresent(result.fallback, forKey: .fallback)
        try c.encode(result.recognizer, forKey: .recognizer)
        try c.encode(result.timings, forKey: .timings)
        try c.encode(HubJSON.string(from: result.createdAt), forKey: .createdAt)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(client, forKey: .client)
        try c.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encode(edited, forKey: .edited)
    }
}

/// Every dictation from every device (history.json), newest first, at most `maxItems` and `maxTextBytes` of text.
/// Each `createdAt` is unique (a new entry is at least 1 ms after the newest), so paging by `before` never skips or
/// repeats one.
@MainActor
public final class HubHistory {
    public nonisolated static let maxItems = 2_000
    /// The most text (raw and text, UTF-8) kept in all: the whole file is rewritten on every change.
    public nonisolated static let maxTextBytes = 8 * 1024 * 1024

    public private(set) var entries: [HubHistoryEntry]
    private let store: DataFileStore
    private let limit: Int
    private let byteLimit: Int

    public init(store: DataFileStore, limit: Int = HubHistory.maxItems, byteLimit: Int = HubHistory.maxTextBytes) {
        self.store = store
        self.limit = limit
        self.byteLimit = byteLimit
        let saved = store.readList(HubHistoryEntry.self, from: HubDataFolder.File.history) ?? []
        entries = Array(saved.sorted { $0.result.createdAt > $1.result.createdAt }.prefix(limit))
        trim()
    }

    /// Drops the oldest entries over `limit` or `byteLimit` (never the newest).
    private func trim() {
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        var bytes = entries.reduce(0) { $0 + Self.bytes($1) }
        while bytes > byteLimit, entries.count > 1 { bytes -= Self.bytes(entries.removeLast()) }
    }

    static func bytes(_ entry: HubHistoryEntry) -> Int { entry.result.raw.utf8.count + entry.result.text.utf8.count }

    public func entry(id: UUID) -> HubHistoryEntry? { entries.first { $0.result.id == id } }

    public func entry(clientRecordingID: UUID) -> HubHistoryEntry? {
        entries.first { $0.result.clientRecordingID == clientRecordingID }
    }

    /// Saves a new dictation and returns it as saved (its `createdAt` may be moved up by a millisecond or two).
    /// One entry per recording: an older entry with the same `clientRecordingID` is replaced.
    @discardableResult
    public func add(_ entry: HubHistoryEntry) -> HubHistoryEntry {
        var entry = entry
        var millis = Self.millis(entry.result.createdAt)
        if let newest = entries.first.map({ Self.millis($0.result.createdAt) }), millis <= newest { millis = newest + 1 }
        entry.result.createdAt = Self.date(millis: millis)
        entries.removeAll { $0.result.clientRecordingID == entry.result.clientRecordingID }
        entries.insert(entry, at: 0)
        trim()
        save()
        return entry
    }

    public func update(_ entry: HubHistoryEntry) {
        guard let i = entries.firstIndex(where: { $0.result.id == entry.result.id }) else { return }
        entries[i] = entry
        trim()
        save()
    }

    /// The entry that was deleted, or nil when there was none.
    @discardableResult
    public func delete(id: UUID) -> HubHistoryEntry? {
        guard let i = entries.firstIndex(where: { $0.result.id == id }) else { return nil }
        let gone = entries.remove(at: i)
        save()
        return gone
    }

    /// `GET /v1/history`: up to `limit` entries older than `before`, newest first.
    public func page(limit: Int, before: Date?) -> HistoryPage {
        let older = before.map { cut in entries.filter { Self.millis($0.result.createdAt) < Self.millis(cut) } } ?? entries
        let items = Array(older.prefix(limit))
        let more = older.count > items.count
        return HistoryPage(items: items.map(\.item),
                           nextBefore: more ? items.last.map { HubJSON.string(from: $0.result.createdAt) } : nil)
    }

    private func save() { store.write(entries, to: HubDataFolder.File.history) }

    /// Times are compared in whole milliseconds, as the protocol carries them.
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
    static func date(millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1_000) }
}
