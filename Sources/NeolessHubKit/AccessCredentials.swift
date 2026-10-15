import Darwin
import Foundation
import NeolessCloud
import NeolessCore

/// 双重锁 (docs/hub.md, "Access 双重锁"): the Cloudflare Access service token the hub puts into pairing links, so
/// every device request carries it and Cloudflare lets it through to the Neo. `cloudflare-access.json` in the data
/// folder, 0600 from the moment it is written (`PrivateFile`); never printed, logged or sent anywhere but in a link.
/// The hub does not need it to check requests: Cloudflare checks the token at the edge.
public struct AccessCredentials: Sendable {
    public let folder: HubDataFolder

    public init(folder: HubDataFolder) { self.folder = folder }

    /// The file's contents.
    public struct Saved: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                         CustomReflectable {
        public var clientID: String
        public var clientSecret: String
        public var savedAt: Date

        public var access: HubAccess? { try? HubAccess(clientID: clientID, clientSecret: clientSecret) }

        // Never the secret, in a log line or a debugger's dump.
        public var description: String { "AccessCredentials.Saved(\(access?.maskedID ?? "…"))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror {
            Mirror(self, children: ["clientID": access?.maskedID ?? "…", "savedAt": savedAt], displayStyle: .struct)
        }
    }

    public var url: URL { folder.file(HubDataFolder.File.access) }

    /// The saved credentials; nil when none are. Throws when the file is there but cannot be used: a pairing link
    /// made without them would be stopped at Cloudflare, so that is never done quietly.
    public func load() throws -> (access: HubAccess, savedAt: Date)? {
        let path = url.path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw HubSetupError("读不出 \(path)：\(String(cString: strerror(errno)))。运行 neoless-hub access set 重新存入")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw HubSetupError("\(path) 不是当前用户的普通文件，没有使用。运行 neoless-hub access clear 再 access set")
        }
        // Readable by others (copied in by hand): only the owner may read it.
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let saved = try? HubJSON.decode(Saved.self, from: data), let access = saved.access else {
            throw HubSetupError("\(path) 的内容不对。运行 neoless-hub access set 重新存入")
        }
        return (access, saved.savedAt)
    }

    /// Saves (or replaces) the credentials, 0600.
    public func save(_ access: HubAccess, at date: Date = Date()) throws {
        let saved = Saved(clientID: access.clientID, clientSecret: access.clientSecret, savedAt: HubJSON.rounded(date))
        guard let data = try? HubJSON.encode(saved), PrivateFile.write(data, to: url) else {
            throw HubSetupError("没能保存 \(url.path)")
        }
    }

    /// Deletes the file. Returns whether there was one.
    @discardableResult
    public func clear() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw HubSetupError("没能删除 \(url.path)")
        }
        return true
    }
}

/// Reads what `neoless-hub access set` is given: from the terminal with prompts (the secret without echo), or line
/// by line from a pipe (`printf '%s\n%s\n' "$ID" "$SECRET" | neoless-hub access set`), so the secret never has to
/// be an argument that `ps` and the shell history would show.
public enum SecretInput {
    /// One line of input, or nil at its end. `prompt` goes to stderr, and only when stdin is a terminal; with
    /// `hidden` what is typed is not echoed.
    public typealias Reader = (_ prompt: String, _ hidden: Bool) -> String?

    public static let standard: Reader = { prompt, hidden in
        let terminal = isatty(STDIN_FILENO) == 1
        if terminal { FileHandle.standardError.write(Data(prompt.utf8)) }
        guard terminal, hidden else { return readLine(strippingNewline: true) }
        return withoutEcho { readLine(strippingNewline: true) }
    }

    /// The terminal's settings while echo is off, for the Ctrl-C handler to put back.
    nonisolated(unsafe) private static var saved = termios()

    /// Runs `body` with the terminal's echo off (line editing stays), and puts it back after, on Ctrl-C too.
    static func withoutEcho<T>(_ body: () -> T) -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return body() }
        saved = original
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        let previous = signal(SIGINT) { _ in
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &SecretInput.saved)
            _exit(130)
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            signal(SIGINT, previous)
            // The Return that ended the line was not echoed either.
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return body()
    }
}

/// What `neoless-hub access …`, `pair` and `status` say about 双重锁.
public enum AccessText {
    /// `status` and `access status`: on or off, the masked Client ID (never the secret), and the hub's own check.
    public static func status(saved: (access: HubAccess, savedAt: Date)?, requireAccess: Bool) -> [String] {
        var lines: [String] = []
        if let saved {
            lines.append("双重锁：已开启（Cloudflare 门禁凭据 Client ID \(saved.access.maskedID)，\(stamp(saved.savedAt)) 存入；配对链接会带上它）")
        } else {
            lines.append("双重锁：未开启（只靠设备密钥。设好 Cloudflare Access 后运行 neoless-hub access set）")
        }
        if requireAccess {
            lines.append("Hub 自己也看门禁标记：开（不带 Cloudflare 门禁标记的请求一律 403，/v1/ping 除外；只看在不在，不验签名）")
            if saved == nil { lines.append("注意：还没存门禁凭据，新配对的设备过不了 Cloudflare 门禁") }
        } else {
            lines.append("Hub 自己看门禁标记：关（neoless-hub access require on 打开）")
        }
        return lines
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
