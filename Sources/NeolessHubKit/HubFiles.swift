import Darwin
import Foundation
import NeolessCloud
import NeolessCore

/// The hub's data folder: ~/Library/Application Support/neoless-hub, owner-only (0700, files 0600). Devices,
/// dictionary, learning, history, settings, the ChatGPT login and the worker secret all live here, on the Neo only.
public struct HubDataFolder: Sendable {
    public let store: DataFileStore
    public var url: URL { store.directory }

    public init(store: DataFileStore) { self.store = store }

    /// ~/Library/Application Support/neoless-hub.
    public static func standard() -> HubDataFolder {
        HubDataFolder(store: DataFileStore.applicationSupport(Hub.dataFolderName))
    }

    /// Another folder (tests, a trial run on a spare port), created 0700 when missing and tightened to 0700.
    public static func at(_ url: URL) throws -> HubDataFolder {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return HubDataFolder(store: DataFileStore(directory: url))
    }

    public func file(_ name: String) -> URL { store.url(name) }

    /// File names in the folder.
    public enum File {
        public static let devices = "devices.json"
        public static let devicesLock = "devices.lock"
        public static let vocabulary = "vocabulary.json"
        public static let vocabularyGeneration = "vocabulary-generation.json"
        public static let learning = "learning.json"
        /// 我的习惯: the user's own writing preferences (`Habits`).
        public static let habits = "habits.json"
        public static let habitsGeneration = "habits-generation.json"
        public static let history = "history.json"
        public static let settings = "settings.json"
        /// The Cloudflare Access service token pairing links carry (双重锁, `AccessCredentials`).
        public static let access = "cloudflare-access.json"
    }
}

/// Files only their owner may read (0600) from the moment they exist: written to a new file next to the target,
/// created 0600, then renamed over it. For what carries a secret (the Access credentials, a pairing QR code).
enum PrivateFile {
    static func write(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        let synced = fsync(fd) == 0
        let closed = close(fd) == 0
        guard written, synced, closed, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}

/// Which version of a file is on disk: changes when it is rewritten (the atomic writes make a new inode).
struct FileStamp: Equatable, Sendable {
    let modified: Date?
    let size: Int?
    let inode: Int?

    /// nil when the file does not exist.
    static func of(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(modified: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.intValue,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.intValue)
    }
}

/// A Codable file another process may rewrite (`neoless-hub server <地址>` while `serve` runs): read again
/// whenever it changed on disk.
final class WatchedFile<Value: Codable & Sendable>: @unchecked Sendable {
    private let store: DataFileStore
    private let name: String
    private let fallback: Value
    private let lock = NSLock()
    private var stamp: FileStamp?
    private var cached: Value

    init(store: DataFileStore, name: String, fallback: Value) {
        self.store = store
        self.name = name
        self.fallback = fallback
        stamp = FileStamp.of(store.url(name))
        cached = store.read(Value.self, from: name) ?? fallback
    }

    var value: Value {
        lock.withLock {
            let now = FileStamp.of(store.url(name))
            if now != stamp {
                stamp = now
                cached = store.read(Value.self, from: name) ?? fallback
            }
            return cached
        }
    }

    @discardableResult
    func write(_ value: Value) -> Bool {
        lock.withLock {
            guard store.write(value, to: name) else { return false }
            cached = value
            stamp = FileStamp.of(store.url(name))
            return true
        }
    }
}

/// An advisory lock on a file in the data folder, so `serve` and the `pair` / `revoke` commands never write
/// devices.json over each other's changes.
enum FileLock {
    static func withLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }
}

/// Something about the data folder or the worker secret that keeps the hub from starting.
public struct HubSetupError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The ASR worker's shared secret (docs/hub.md, "ASR worker"): one line of base64url in
/// `<data folder>/worker-secret`, 0600. Whichever of hub and worker starts first creates it: the value is written
/// to a temporary file first and then hard-linked into place, so the other side sees nothing or all of it.
public enum WorkerSecret {
    public static let minimumLength = 16

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(Hub.workerSecretFileName) }

    /// Reads the secret, creating it when missing. An existing file that others can read is tightened to 0600;
    /// one that is a link, not a plain file, or not the current user's is refused.
    public static func loadOrCreate(in folder: URL) throws -> String {
        let path = url(in: folder).path
        if let value = try read(path) { return value }
        var template = Array(folder.appendingPathComponent(".worker-secret-XXXXXX").path.utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw HubSetupError("没法创建 worker 密钥：\(String(cString: strerror(errno)))") }
        let temporary = String(cString: template)
        defer { unlink(temporary) }
        fchmod(fd, 0o600)
        let bytes = Array(HubToken.generate().utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
        close(fd)
        guard written == bytes.count else { throw HubSetupError("没法写入 worker 密钥") }
        // EEXIST: the worker created it a moment ago; use theirs.
        if link(temporary, path) != 0, errno != EEXIST {
            throw HubSetupError("没法保存 worker 密钥：\(String(cString: strerror(errno)))")
        }
        guard let value = try read(path) else { throw HubSetupError("worker 密钥不见了") }
        return value
    }

    /// The secret, or nil when the file does not exist.
    static func read(_ path: String) throws -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw HubSetupError("worker 密钥 \(path) 不能是链接") }
            throw HubSetupError("无法读取 worker 密钥 \(path)：\(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw HubSetupError("worker 密钥 \(path) 不是普通文件")
        }
        guard info.st_uid == getuid() else { throw HubSetupError("worker 密钥 \(path) 不是当前用户的文件") }
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count >= 0 else { throw HubSetupError("无法读取 worker 密钥 \(path)") }
        let value = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= minimumLength else { throw HubSetupError("worker 密钥 \(path) 是空的或太短") }
        return value
    }
}
