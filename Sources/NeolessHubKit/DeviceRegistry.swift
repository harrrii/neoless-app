import Foundation
import NeolessCloud
import NeolessCore

/// One paired device as devices.json keeps it: the SHA-256 of its token, never the token.
public struct HubDevice: Codable, Equatable, Sendable {
    public var name: String
    /// `HubToken.hash` of the device token.
    public var tokenHash: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    /// Set by `neoless-hub revoke`: the token is answered with 403 from then on.
    public var revokedAt: Date?

    public init(name: String, tokenHash: String, createdAt: Date, lastSeenAt: Date? = nil, revokedAt: Date? = nil) {
        self.name = name; self.tokenHash = tokenHash; self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt; self.revokedAt = revokedAt
    }

    public var isRevoked: Bool { revokedAt != nil }
}

/// The paired devices (devices.json). `serve` reads the file again whenever `pair` or `revoke` changed it, so a
/// new device works and a revoked one stops at once, without a restart. Every change goes through a file lock.
public final class DeviceRegistry: @unchecked Sendable {
    public enum Lookup: Equatable {
        case device(HubDevice)
        case revoked(HubDevice)
        case unknown
    }

    public enum Failure: LocalizedError, Equatable {
        case badName, notFound(String), notSaved
        public var errorDescription: String? {
            switch self {
            case .badName: return "设备名不能为空，最多 40 个字，不能有换行"
            case .notFound(let name): return "没有叫“\(name)”的设备"
            case .notSaved: return "没能保存 devices.json"
            }
        }
    }

    public static let maxNameLength = HubPairing.maxNameLength
    /// lastSeenAt is written at most this often per device.
    static let seenInterval: TimeInterval = 60

    private let folder: HubDataFolder
    private let lock = NSLock()
    private var devices: [HubDevice] = []
    private var stamp: FileStamp?
    /// Last request per token hash, newer than the file says.
    private var seen: [String: Date] = [:]

    public init(folder: HubDataFolder) {
        self.folder = folder
        lock.withLock { reloadIfChanged(force: true) }
    }

    private var fileURL: URL { folder.file(HubDataFolder.File.devices) }
    private var lockURL: URL { folder.file(HubDataFolder.File.devicesLock) }

    /// Every device, revoked ones too, oldest first.
    public var all: [HubDevice] {
        lock.withLock {
            reloadIfChanged()
            return devices.map { device in
                var device = device
                if let at = seen[device.tokenHash], at > (device.lastSeenAt ?? .distantPast) { device.lastSeenAt = at }
                return device
            }
        }
    }

    /// A new token for `name`. An active device of the same name is replaced: its old token stops working.
    /// Returns the token (shown once, never stored) and whether a device was replaced.
    public func pair(name: String, now: Date = Date()) throws -> (token: String, replaced: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(name) else { throw Failure.badName }
        let token = HubToken.generate()
        var replaced = false
        try mutate { list in
            for i in list.indices where list[i].revokedAt == nil && Self.sameName(list[i].name, name) {
                list[i].revokedAt = now
                replaced = true
            }
            list.append(HubDevice(name: name, tokenHash: HubToken.hash(token), createdAt: now))
        }
        return (token, replaced)
    }

    /// Revokes every active device called `name` (any case). Their requests get 403 from now on.
    @discardableResult
    public func revoke(name: String, now: Date = Date()) throws -> Int {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var count = 0
        try mutate { list in
            for i in list.indices where list[i].revokedAt == nil && Self.sameName(list[i].name, name) {
                list[i].revokedAt = now
                count += 1
            }
        }
        guard count > 0 else { throw Failure.notFound(name) }
        return count
    }

    /// Which device a bearer token belongs to.
    public func lookup(token: String) -> Lookup {
        guard HubToken.isWellFormed(token) else { return .unknown }
        return lock.withLock {
            reloadIfChanged()
            if let active = devices.first(where: { $0.revokedAt == nil && HubToken.matches(token, hash: $0.tokenHash) }) {
                return .device(active)
            }
            if let old = devices.first(where: { HubToken.matches(token, hash: $0.tokenHash) }) { return .revoked(old) }
            return .unknown
        }
    }

    /// Notes a request from `device`; devices.json gets the time at most once a minute per device.
    public func touch(_ device: HubDevice, now: Date = Date()) {
        let due: Bool = lock.withLock {
            seen[device.tokenHash] = now
            let saved = devices.first { $0.tokenHash == device.tokenHash }?.lastSeenAt ?? .distantPast
            return now.timeIntervalSince(saved) >= Self.seenInterval
        }
        if due { try? mutate { _ in } }
    }

    // MARK: Private

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maxNameLength
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == b.lowercased()
    }

    /// Read-modify-write under the file lock, starting from what is on disk now; pending lastSeen times go in too.
    private func mutate(_ change: (inout [HubDevice]) -> Void) throws {
        try FileLock.withLock(lockURL) {
            try lock.withLock {
                reloadIfChanged(force: true)
                var list = devices
                change(&list)
                for i in list.indices {
                    if let at = seen[list[i].tokenHash], at > (list[i].lastSeenAt ?? .distantPast) { list[i].lastSeenAt = at }
                }
                guard list != devices || FileStamp.of(fileURL) == nil else { return }
                guard folder.store.write(list, to: HubDataFolder.File.devices) else { throw Failure.notSaved }
                devices = list
                stamp = FileStamp.of(fileURL)
            }
        }
    }

    /// Call with `lock` held.
    private func reloadIfChanged(force: Bool = false) {
        let now = FileStamp.of(fileURL)
        guard force || now != stamp else { return }
        stamp = now
        devices = folder.store.readList(HubDevice.self, from: HubDataFolder.File.devices) ?? []
    }
}

/// At most `limit` requests per key in any `window` seconds.
public struct RateLimiter: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var hits: [String: [Date]] = [:]

    public init(limit: Int = Hub.requestsPerMinute, window: TimeInterval = 60) {
        self.limit = limit; self.window = window
    }

    /// Counts the request and says whether it is within the limit. Refused requests are not counted.
    public mutating func allow(_ key: String, now: Date = Date()) -> Bool {
        var list = hits[key, default: []].filter { now.timeIntervalSince($0) < window }
        guard list.count < limit else {
            hits[key] = list
            return false
        }
        list.append(now)
        hits[key] = list
        return true
    }
}
