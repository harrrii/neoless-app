import Foundation

/// 录音备份: the last `keep` recordings, as they were sent (or would have been), in a folder of their own, so
/// one the Neo lost (a restart while it held the pieces, a worker that hung) or turned into this Mac's text can
/// be heard again and recognised again (历史记录 › 用 Neo 重新识别). Named by the dictation's id, which is its
/// history record's (`<id>.m4a`). About 240 KB a minute: ten long recordings are a few tens of MB.
/// Owner-only (0700 folder, 0600 files), like the other data files.
public final class RecordingBackup: @unchecked Sendable {
    public static let keep = 10

    public let directory: URL
    public let keep: Int
    private let lock = NSLock()

    public init(directory: URL, keep: Int = RecordingBackup.keep) {
        self.directory = directory
        self.keep = keep
    }

    /// Writes the recording and drops the oldest past `keep`. False when nothing was written.
    @discardableResult
    public func save(_ audio: EncodedAudio, id: UUID) -> Bool {
        lock.withLock {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                for type in HubAudioType.allCases where type != audio.type { try? fm.removeItem(at: url(id, type)) }
                let target = url(id, audio.type)
                try audio.data.write(to: target, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                return false
            }
            for old in Self.overflow(files(), keep: keep) { try? fm.removeItem(at: old.url) }
            return true
        }
    }

    /// The saved recording of dictation `id`, if it is still kept.
    public func file(for id: UUID) -> URL? {
        HubAudioType.allCases.map { url(id, $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func load(_ id: UUID) -> (data: Data, type: HubAudioType)? {
        guard let url = file(for: id), let data = try? Data(contentsOf: url),
              let type = HubAudioType.allCases.first(where: { $0.fileExtension == url.pathExtension }) else { return nil }
        return (data, type)
    }

    public func remove(_ id: UUID) {
        lock.withLock { for type in HubAudioType.allCases { try? FileManager.default.removeItem(at: url(id, type)) } }
    }

    public func removeAll() {
        lock.withLock {
            for file in files() { try? FileManager.default.removeItem(at: file.url) }
        }
    }

    /// The ids of the recordings kept, newest first.
    public var ids: [UUID] {
        lock.withLock { files().sorted { $0.date > $1.date }.compactMap { UUID(uuidString: $0.url.deletingPathExtension().lastPathComponent) } }
    }

    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var date: Date
        public init(url: URL, date: Date) { self.url = url; self.date = date }
    }

    /// The entries past the newest `keep`, oldest last.
    public static func overflow(_ entries: [Entry], keep: Int) -> [Entry] {
        Array(entries.sorted { $0.date > $1.date }.dropFirst(max(0, keep)))
    }

    private func url(_ id: UUID, _ type: HubAudioType) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(type.fileExtension)")
    }

    private func files() -> [Entry] {
        let extensions = Set(HubAudioType.allCases.map(\.fileExtension))
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { extensions.contains($0.pathExtension) }.map { url in
            Entry(url: url, date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }
}

