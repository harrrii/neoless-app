import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

// 双重锁 on the Neo: `neoless-hub access …`, pairing links that carry the Cloudflare Access service token, and the
// hub's own optional check that a request came through Access.

private let clientID = "0123456789abcdef0123456789abcdef.access"
private let clientSecret = "3f0c9a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7"

/// Answers the prompts of `access set` in order, as a pipe would; records whether each one hides what is typed.
private final class Answers: @unchecked Sendable {
    private var lines: [String?]
    private(set) var asked: [(prompt: String, hidden: Bool)] = []
    init(_ lines: [String?]) { self.lines = lines }
    var reader: SecretInput.Reader {
        { prompt, hidden in
            self.asked.append((prompt, hidden))
            return self.lines.isEmpty ? nil : self.lines.removeFirst()
        }
    }
}

@MainActor
@Suite struct HubAccessCommandTests {
    private func parse(_ line: String) throws -> HubCommandLine {
        try HubCommandLine.parse(line.split(separator: " ").map(String.init))
    }

    @Test func accessCommands() throws {
        #expect(try parse("access set").command == .access(.set(clientID: nil)))
        #expect(try parse("access set --id \(clientID)").command == .access(.set(clientID: clientID)))
        #expect(try parse("access status").command == .access(.status))
        #expect(try parse("access clear").command == .access(.clear))
        #expect(try parse("access require on").command == .access(.require(true)))
        #expect(try parse("access require off").command == .access(.require(false)))
        #expect(try parse("access status --data-dir /tmp/hub").dataDirectory == "/tmp/hub")
        for line in ["access", "access open", "access require", "access require maybe", "access set extra",
                     "access status x", "access require on x", "pair --name Mac --id \(clientID)", "access clear --id x",
                     "access set --id"] {
            #expect(throws: HubCommandLine.Failure.self, "\(line)") { try parse(line) }
        }
        #expect(HubCommandLine.usage.contains("neoless-hub access set"))
    }

    @Test func setStatusAndClear() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        let credentials = AccessCredentials(folder: folder)
        #expect(try credentials.load() == nil)

        // Piped: the ID on the first line, the secret on the second; the secret is asked for hidden.
        let answers = Answers([" \(clientID) ", clientSecret])
        #expect(try HubCommands.access(.set(clientID: nil), folder: folder, input: answers.reader) == 0)
        #expect(answers.asked.map(\.hidden) == [false, true])
        let saved = try #require(try credentials.load())
        #expect(saved.access.clientID == clientID && saved.access.clientSecret == clientSecret)
        // Owner-only, in the data folder.
        let mode = try FileManager.default.attributesOfItem(atPath: credentials.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(credentials.url.lastPathComponent == "cloudflare-access.json")

        // With --id only the secret is read.
        let secretOnly = Answers(["another-secret-value-123"])
        #expect(try HubCommands.access(.set(clientID: "0123456789abcdef.access"), folder: folder, input: secretOnly.reader) == 0)
        #expect(secretOnly.asked.map(\.hidden) == [true])
        #expect(try credentials.load()?.access.clientSecret == "another-secret-value-123")

        // Status shows the masked ID, never the secret.
        let lines = AccessText.status(saved: try credentials.load(), requireAccess: false)
        #expect(lines.first?.hasPrefix("双重锁：已开启") == true)
        #expect(lines.joined().contains("0123…cdef.access"))
        #expect(!lines.joined().contains("another-secret-value-123") && !lines.joined().contains("0123456789abcdef.access"))
        #expect(AccessText.status(saved: nil, requireAccess: false).first?.hasPrefix("双重锁：未开启") == true)
        #expect(AccessText.status(saved: nil, requireAccess: true).contains { $0.contains("过不了 Cloudflare 门禁") })
        // The hub's own check is said for what it is: only whether the header is there.
        #expect(AccessText.status(saved: nil, requireAccess: true).contains { $0.contains("不验签名") })
        #expect(HubCommandLine.usage.contains("谁都能伪造"))

        #expect(try HubCommands.access(.clear, folder: folder) == 0)
        #expect(try credentials.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: credentials.url.path))
        #expect(try credentials.clear() == false)
    }

    @Test func theSavedFileNeverPrintsTheSecret() throws {
        let saved = AccessCredentials.Saved(clientID: clientID, clientSecret: clientSecret, savedAt: Date(timeIntervalSince1970: 0))
        var dumped = ""
        dump(saved, to: &dumped)
        for text in [String(describing: saved), String(reflecting: saved), "\(saved)", dumped] {
            #expect(!text.contains(clientSecret) && !text.contains("3f0c9a1b") && !text.contains(clientID), "\(text)")
        }
        #expect(String(describing: saved).contains("0123…cdef.access"))
        // How to hand a link over leaves no synced copy behind.
        #expect(HubCommands.handOver.contains("AirDrop") && HubCommands.handOver.contains("最近删除"))
    }

    @Test func badInputIsRefused() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        for lines: [String?] in [[], [clientID], [clientID, ""], [clientID, "short"], ["has space.access", clientSecret],
                                 [clientSecret, clientID], [clientSecret, clientSecret]] {
            #expect(throws: HubSetupError.self, "\(lines)") {
                try HubCommands.access(.set(clientID: nil), folder: folder, input: Answers(lines).reader)
            }
        }
        #expect(try AccessCredentials(folder: folder).load() == nil)
        // Swapped is said as such.
        #expect(throws: HubSetupError("看起来 Client ID 和 Client Secret 填反了：Client ID 以 .access 结尾")) {
            try HubCommands.readAccess(clientID: nil, input: Answers([clientSecret, clientID]).reader)
        }
    }

    @Test func pairingLinksCarryThem() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        let plain = try HubCommands.makePairing(folder: folder, name: "iPhone", server: Hub.exampleServer).pairing
        #expect(plain.access == nil && !plain.url.absoluteString.contains("cfid"))

        try AccessCredentials(folder: folder).save(try HubAccess(clientID: clientID, clientSecret: clientSecret))
        let (pairing, replaced) = try HubCommands.makePairing(folder: folder, name: "MacBook Air", server: Hub.exampleServer)
        #expect(!replaced)
        #expect(pairing.access == (try HubAccess(clientID: clientID, clientSecret: clientSecret)))
        let parsed = try HubPairing(link: pairing.url.absoluteString)
        #expect(parsed.access?.clientSecret == clientSecret && parsed.token == pairing.token)
        // The command end to end, QR code included.
        let qr = dir.appendingPathComponent("pair.png").path
        #expect(try await HubCommands.run(HubCommandLine(command: .pair(name: "iPad", server: Hub.exampleServer, qr: qr),
                                                         dataDirectory: dir.path)) == 0)
        #expect(FileManager.default.fileExists(atPath: qr))

        // A file that cannot be used stops pairing instead of leaving the credentials out quietly.
        try Data("{".utf8).write(to: AccessCredentials(folder: folder).url)
        #expect(throws: HubSetupError.self) {
            try HubCommands.makePairing(folder: folder, name: "Mac", server: Hub.exampleServer)
        }
        #expect(!DeviceRegistry(folder: folder).all.contains { $0.name == "Mac" })
    }

    @Test func requireSwitchesTheSetting() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        #expect(HubConfig().requireAccess == false)
        #expect(try HubCommands.access(.require(true), folder: folder) == 0)
        let config = folder.store.read(HubConfig.self, from: HubDataFolder.File.settings)
        #expect(config?.requireAccess == true && config?.autoStructured == true)
        #expect(try HubCommands.access(.require(false), folder: folder) == 0)
        #expect(folder.store.read(HubConfig.self, from: HubDataFolder.File.settings)?.requireAccess == false)
        // Older files without the key read as off.
        let old = try HubJSON.decode(HubConfig.self, from: Data(#"{"fastTier":false}"#.utf8))
        #expect(old.requireAccess == false && !old.fastTier)
    }

    // MARK: The hub's own check

    @Test func requireAccessRefusesWhatDidNotComeThroughIt() async throws {
        let hub = try HubFixture()
        // Off (the default): no Access header needed.
        #expect(try await hub.send(.get, HubPath.health).status == .ok)

        #expect(hub.folder.store.write(HubConfig(requireAccess: true), to: HubDataFolder.File.settings))
        let refused = try await hub.send(.get, HubPath.health)
        #expect(refused.status == .forbidden)
        let body = try #require(errorBody(refused))
        #expect(body.code == HubErrorCode.accessRequired && !body.retryable)
        #expect(body.error.contains("Cloudflare 门禁"))
        // Checked before the token: nothing about it is said to what did not come through Access.
        #expect(try await hub.send(.get, HubPath.health, headers: [:]).status == .forbidden)
        #expect(try await hub.send(.get, HubPath.health, headers: hub.headers([HubServer.accessJWTHeader: " "])).status == .forbidden)

        // Through Access: the token decides as before.
        let jwt: [HTTPField.Name: String] = [HubServer.accessJWTHeader: "eyJhbGciOiJSUzI1NiJ9.e30.sig"]
        #expect(try await hub.send(.get, HubPath.health, headers: hub.headers(jwt)).status == .ok)
        #expect(try await hub.send(.get, HubPath.health, headers: hub.headers(jwt, authorized: false)).status == .unauthorized)
        // /v1/ping is not checked (the local `status` uses it, and it says nothing).
        #expect(try await hub.send(.get, HubPath.ping, headers: [:]).status == .ok)

        #expect(hub.folder.store.write(HubConfig(requireAccess: false), to: HubDataFolder.File.settings))
        #expect(try await hub.send(.get, HubPath.health).status == .ok)
    }
}
