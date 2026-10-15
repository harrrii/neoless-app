import Foundation

/// JSON data files in one folder (history, dictionary, learning, the ChatGPT login), written atomically and
/// owner-only. A file that exists but cannot be read back (a newer or older build, a hand edit, a damaged
/// disk) is never lost: it is set aside under a backup name before anything replaces or deletes it, and
/// while that has not worked it is neither overwritten nor deleted. At every moment the user has the
/// original, a backup, or both, until `purge` deletes them all on purpose (signing out).
public final class DataFileStore: @unchecked Sendable {
    public let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var backups: [String] = []
    /// Files that could not be read and could not be set aside yet.
    private var unprotected = Set<String>()

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Backups made by this store (`history.json.corrupt-20261007-204500`), oldest first, so the window can
    /// say what happened.
    public var recovered: [String] { lock.withLock { backups } }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The decoded file, or nil when it is missing. A file that exists but does not read or decode is moved
    /// aside first (copied when it cannot be moved), so the next save can never overwrite it.
    public func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard FileManager.default.fileExists(atPath: url(name).path) else { return nil }
        if let data = try? Data(contentsOf: url(name)), let value = try? Self.decoder.decode(T.self, from: data) {
            return value
        }
        setAside(name, keepOriginal: false)
        return nil
    }

    /// Like `read`, for a JSON array: records that do not decode are skipped and the rest are kept.
    /// The whole original is copied aside first, because the next save drops those records.
    public func readList<T: Decodable>(_ type: T.Type, from name: String) -> [T]? {
        guard FileManager.default.fileExists(atPath: url(name).path) else { return nil }
        guard let data = try? Data(contentsOf: url(name)),
              let list = try? Self.decoder.decode(LossyList<T>.self, from: data) else {
            setAside(name, keepOriginal: false)
            return nil
        }
        if list.dropped > 0 { setAside(name, keepOriginal: true) }
        return list.elements
    }

    /// Saves `value`, 0600. Returns false, writing nothing, when the file on disk could not be read and
    /// still cannot be backed up.
    @discardableResult
    public func write<T: Encodable>(_ value: T, to name: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), mayReplace(name) else { return false }
        do {
            try data.write(to: url(name), options: .atomic)
        } catch {
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(name).path)
        return true
    }

    /// Deletes the file (clearing learned corrections). Same rule as `write`: a file that could not be read
    /// is deleted only once a backup of it exists. Returns whether the file is gone.
    @discardableResult
    public func remove(_ name: String) -> Bool {
        guard mayReplace(name) else { return false }
        try? FileManager.default.removeItem(at: url(name))
        return !FileManager.default.fileExists(atPath: url(name).path)
    }

    /// Deletes the file and every backup of it, readable or not. For the ChatGPT login: signing out must not
    /// leave a working refresh token behind in `chatgpt-auth.json.corrupt-…`. Returns whether all are gone.
    @discardableResult
    public func purge(_ name: String) -> Bool {
        let fm = FileManager.default
        let backups = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { DataFileBackup.isBackup($0, of: name) }
        for file in [name] + backups { try? fm.removeItem(at: url(file)) }
        let left = ([name] + backups).filter { fm.fileExists(atPath: url($0).path) }
        lock.withLock {
            self.backups.removeAll { DataFileBackup.isBackup($0, of: name) && !left.contains($0) }
            if !left.contains(name) { unprotected.remove(name) }
        }
        return left.isEmpty
    }

    // MARK: Private

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A file that failed to read may be replaced only after it has been set aside.
    private func mayReplace(_ name: String) -> Bool {
        guard lock.withLock({ unprotected.contains(name) }) else { return true }
        guard FileManager.default.fileExists(atPath: url(name).path) else {
            lock.withLock { _ = unprotected.remove(name) }
            return true
        }
        return setAside(name, keepOriginal: false)
    }

    /// Moves (or, with `keepOriginal`, copies) `name` to a fresh backup name. When a move fails it copies
    /// instead; when that fails too, the file is marked so `write` and `remove` leave it alone.
    @discardableResult
    private func setAside(_ name: String, keepOriginal: Bool) -> Bool {
        let fm = FileManager.default
        let backup = DataFileBackup.name(for: name, date: now()) { fm.fileExists(atPath: url($0).path) }
        do {
            if keepOriginal {
                try fm.copyItem(at: url(name), to: url(backup))
            } else {
                do { try fm.moveItem(at: url(name), to: url(backup)) } catch { try fm.copyItem(at: url(name), to: url(backup)) }
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(backup).path)
            lock.withLock {
                backups.append(backup)
                unprotected.remove(name)
            }
            NSLog("neoless: %@ could not be read; kept a copy as %@", name, backup)
            return true
        } catch {
            // A copy that failed half-way is not a backup (the original is still there: it was not moved).
            if fm.fileExists(atPath: url(name).path) { try? fm.removeItem(at: url(backup)) }
            lock.withLock { _ = unprotected.insert(name) }
            NSLog("neoless: %@ could not be read or backed up, leaving it untouched: %@", name, error.localizedDescription)
            return false
        }
    }
}

/// Decodes a JSON array one element at a time, so one record a newer or older build cannot read
/// does not take the whole file with it.
public struct LossyList<Element: Decodable>: Decodable {
    public var elements: [Element]
    /// Elements that failed to decode and were skipped.
    public var dropped: Int

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                dropped += 1
                // Step past the element that failed.
                _ = try? container.decode(Skip.self)
            }
        }
        self.elements = elements
        self.dropped = dropped
    }

    /// Decodes nothing, which still moves the container past the current element.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
}

/// A data file that does not decode is set aside under this name instead of being overwritten.
public enum DataFileBackup {
    /// `history.json.corrupt-20261007-184500` (UTC); `-2`, `-3`… when `exists` says that name is taken,
    /// so a second failure in the same second never overwrites the first backup.
    public static func name(for file: String, date: Date = Date(), exists: (String) -> Bool = { _ in false }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(file).corrupt-\(f.string(from: date))"
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Whether `candidate` is a backup `name(for: file, …)` made.
    public static func isBackup(_ candidate: String, of file: String) -> Bool {
        candidate.hasPrefix("\(file).corrupt-")
    }
}
