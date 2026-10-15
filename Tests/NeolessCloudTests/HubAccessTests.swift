import Foundation
import NeolessCore
import Testing
@testable import NeolessCloud

// 双重锁 (docs/hub.md, "Access 双重锁"): the Cloudflare Access service token in pairing links, the Keychain item
// and every request, and what a device makes of Cloudflare Access stopping a request in front of the hub.

private let token = "dGVzdC10b2tlbi0xMjM0NTY3ODkwYWJjZGVmZ2hpams"
private let access = try! HubAccess(clientID: "0123456789abcdef0123456789abcdef.access",
                                    clientSecret: "3f0c9a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7")
private let fast = HubTimeouts(connect: 0.5, quick: 2, ping: 0.5, hubPolishFloor: 1)
/// Room for a busy machine, for an answer that comes a moment after its request (the stub's redirect, 50 ms). When
/// the suites run together a request can wait half a second for its turn to be sent, with `connect` already
/// counting, and Access turning it away then read as 连不上 Neo. No test that uses these waits a timeout out, so a
/// long one costs nothing.
private let roomy = HubTimeouts(connect: 5, quick: 10, ping: 5, hubPolishFloor: 1)
private let loginPage = "https://example.cloudflareaccess.com/cdn-cgi/access/login/hub.example.com?kid=abc&redirect_url=%2Fv1%2Fhealth"

/// A stubbed host; every request (pings included) goes to `handler`.
private final class AccessHub: @unchecked Sendable {
    let host = stubHost()
    let client: HubClient

    init(access: HubAccess? = access, timeouts: HubTimeouts = fast, _ handler: @escaping StubProtocol.Handler) {
        client = HubClient(server: URL(string: "https://\(host)")!, token: token, access: access,
                           session: StubProtocol.session(), timeouts: timeouts)
        StubProtocol.register(host: host, handler)
    }

    var requests: [StubProtocol.Seen] { StubProtocol.requests(host: host) }
    func done() { StubProtocol.remove(host: host) }
}

private func response(_ status: Int, url: String = "https://hub.example.com/v1/health",
                      headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

@Suite struct HubAccessTests {
    // MARK: Pairing links

    @Test func linkCarriesTheServiceToken() throws {
        let pairing = try HubPairing(server: Hub.exampleServer, token: token, name: "MacBook Air", access: access)
        let link = pairing.url.absoluteString
        #expect(link.contains("&cfid=0123456789abcdef0123456789abcdef.access&cfsecret=3f0c9a1b"))
        #expect(link.hasSuffix("&name=MacBook%20Air"))
        let parsed = try HubPairing(link: link)
        #expect(parsed == pairing && parsed.access == access)
        // Pasted as a link into the Mac's field.
        #expect(try HubPairing(pasted: " \(link)\n", server: Hub.exampleServer, name: "Mac").access == access)
    }

    @Test func oldLinksWithoutItStillWork() throws {
        let old = try HubPairing(link: "neoless://pair?server=https%3A%2F%2Fhub.example.com&token=\(token)&name=iPhone")
        #expect(old.access == nil && old.name == "iPhone")
        #expect(!old.url.absoluteString.contains("cfid"))
        // Empty values are none.
        #expect(try HubPairing(link: "neoless://pair?server=https://hub.example.com&token=\(token)&cfid=&cfsecret=").access == nil)
    }

    @Test func halfOrBadCredentialsAreRefused() {
        let base = "neoless://pair?server=https://hub.example.com&token=\(token)"
        for tail in ["&cfid=0123456789abcdef0123456789abcdef.access", "&cfsecret=3f0c9a1b2c3d4e5f",
                     "&cfid=short&cfsecret=3f0c9a1b2c3d4e5f", "&cfid=01234567%20space.access&cfsecret=3f0c9a1b2c3d4e5f",
                     "&cfid=%E4%B8%AD%E6%96%87%E4%B8%AD%E6%96%87%E4%B8%AD%E6%96%87&cfsecret=3f0c9a1b2c3d4e5f",
                     "&cfid=3f0c9a1b2c3d4e5f&cfsecret=3f0c9a1b2c3d4e5f"] {
            #expect(throws: HubProtocolError.badAccess, "\(tail)") { try HubPairing(link: base + tail) }
        }
        #expect(HubProtocolError.badAccess.errorDescription == "配对链接里的 Cloudflare 门禁凭据不完整或不对")
    }

    @Test func theSecretIsNeverShown() throws {
        #expect(access.maskedID == "0123…cdef.access")
        #expect(try HubAccess(clientID: "plain-client-id-123", clientSecret: "x-secret-value").maskedID == "plai…-123")
        #expect(try HubAccess(clientID: "tiny.access", clientSecret: "x-secret-value").maskedID == "….access")
        #expect(!String(describing: access).contains(access.clientSecret))
        #expect(!"\(access)".contains("3f0c9a1b"))
        #expect(try HubAccess(clientID: access.clientSecret, clientSecret: access.clientID).looksSwapped)
        #expect(!access.looksSwapped)
        #expect(access.headers == ["CF-Access-Client-Id": access.clientID, "CF-Access-Client-Secret": access.clientSecret])
    }

    // MARK: Keychain

    @Test func keychainKeepsThemWithTheToken() throws {
        try withTestDefaults { defaults in
            let secrets = MemorySecretStore()
            let store = HubPairingStore(defaults: defaults, secrets: secrets)
            let pairing = try HubPairing(server: Hub.exampleServer, token: token, name: "MacBook Air", access: access)
            try store.save(pairing)
            #expect(try store.load() == pairing)
            #expect(try store.client().hasAccess)
            // One Keychain item, JSON with the server, the token and the credentials.
            let value = try #require(try secrets.read(HubPairingStore.tokenAccount))
            let object = try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["server", "token", "access"])
            #expect((object["access"] as? [String: String]) == ["clientID": access.clientID, "clientSecret": access.clientSecret])
            // Nothing of them in UserDefaults.
            let strings = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
            #expect(strings.allSatisfy { !$0.contains(access.clientSecret) && !$0.contains(access.clientID) })

            // An item saved before 双重锁 still loads, without credentials (absent or null).
            try secrets.write(#"{"server":"https://hub.example.com","token":"\#(token)"}"#, for: HubPairingStore.tokenAccount)
            #expect(try store.load()?.access == nil && store.load()?.token == token)
            #expect(try store.client().hasAccess == false)
            try secrets.write(#"{"server":"https://hub.example.com","token":"\#(token)","access":null}"#,
                              for: HubPairingStore.tokenAccount)
            #expect(try store.load()?.access == nil && store.load()?.token == token)
        }
    }

    @Test func unreadableCredentialsAreNotNone() throws {
        try withTestDefaults { defaults in
            let secrets = MemorySecretStore()
            let store = HubPairingStore(defaults: defaults, secrets: secrets)
            try store.save(try HubPairing(server: Hub.exampleServer, token: token, name: "MacBook Air", access: access))
            // Credentials that do not read back (cut short, edited, or checked more strictly now): no client is made,
            // so nothing goes out with the token alone; the device says to pair again.
            for bad in [#"{"clientID":"x"}"#, #"{"clientID":"short","clientSecret":"3f0c9a1b2c3d4e5f"}"#, #""oops""#, "[]",
                        #"{"clientID":"\#(access.clientID)","clientSecret":"\#(access.clientID)"}"#] {
                try secrets.write(#"{"server":"https://hub.example.com","token":"\#(token)","access":\#(bad)}"#,
                                  for: HubPairingStore.tokenAccount)
                #expect(throws: HubPairingStoreError.accessUnreadable, "\(bad)") { try store.load() }
                #expect(throws: HubPairingStoreError.accessUnreadable, "\(bad)") { try store.client() }
            }
            #expect(HubPairingStoreError.accessUnreadable.errorDescription?.contains("重新配对") == true)
            // The display copy of the server stays, so pairing again with the same Neo keeps what waits to be sent.
            #expect(store.server == Hub.exampleServer)
            // A broken token or server is still no pairing at all, whatever the credentials.
            try secrets.write(#"{"server":"https://hub.example.com","token":"!","access":{"clientID":"x"}}"#,
                              for: HubPairingStore.tokenAccount)
            #expect(try store.load() == nil)
        }
    }

    @Test func nothingPrintsTheSecrets() throws {
        let pairing = try HubPairing(server: Hub.exampleServer, token: token, name: "MacBook Air", access: access)
        let stored = HubPairingStore.Stored(server: Hub.exampleServer.absoluteString, token: token, access: access)
        let client = HubClient(pairing: pairing, session: StubProtocol.session())
        func shown(_ value: Any) -> [String] {
            var dumped = ""
            dump(value, to: &dumped)
            return [String(describing: value), String(reflecting: value), dumped, "\(value)",
                    Mirror(reflecting: value).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: ", ")]
        }
        for value in [access, pairing, stored, client] as [Any] {
            for text in shown(value) {
                #expect(!text.contains(access.clientSecret) && !text.contains("3f0c9a1b"), "\(text)")
                #expect(!text.contains(token) && !text.contains(access.clientID), "\(text)")
            }
        }
        // What is shown: the server, the name and the masked Client ID.
        #expect(String(describing: pairing).contains("hub.example.com") && String(describing: pairing).contains("0123…cdef.access"))
        #expect(String(describing: try HubPairing(server: Hub.exampleServer, token: token, name: "iPhone")).contains("access: none"))
    }

    // MARK: Requests

    @Test func everyRequestCarriesTheHeaders() async throws {
        let request = DictationRequest(mode: .natural, autoStructured: true, durationSeconds: 1, client: .mac, clientVersion: "1.2.0")
        let answer = DictationResult(clientRecordingID: request.clientRecordingID, raw: "好", text: "好。", mode: .natural,
                                     polished: true, recognizer: .qwen3ASR, timings: HubTimings(decodeMs: 1, asrMs: 1, polishMs: 1, totalMs: 3))
        let health = HubHealth(version: "1.2.0", asr: .init(ready: true, model: "m"), chatgpt: .init(ready: true), device: "Mac")
        let hub = AccessHub(timeouts: roomy) { request, _, _ in
            switch request.url?.path {
            case HubPath.ping: return .respond(status: 200, body: Data(#"{"ok":true}"#.utf8))
            case HubPath.health: return .respond(status: 200, body: json(health))
            default: return .respond(status: 200, body: json(answer))
            }
        }
        defer { hub.done() }
        _ = try await hub.client.ping()
        _ = try await hub.client.health()
        _ = try await hub.client.dictate(audio: Data(count: 100), type: .m4a, request: request)
        let seen = hub.requests
        // ping, health, the dictation and the ping sent alongside it.
        #expect(seen.count == 4)
        for item in seen {
            #expect(item.request.value(forHTTPHeaderField: "CF-Access-Client-Id") == access.clientID, "\(item.request.url!)")
            #expect(item.request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == access.clientSecret, "\(item.request.url!)")
        }
        // The ping still carries no device token.
        #expect(seen.first { $0.request.url?.path == HubPath.ping }?.request.value(forHTTPHeaderField: "Authorization") == nil)

        // Without 双重锁, no such header at all.
        let plain = AccessHub(access: nil, timeouts: roomy) { _, _, _ in .respond(status: 200, body: json(health)) }
        defer { plain.done() }
        _ = try await plain.client.health()
        #expect(plain.requests.first?.request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(plain.requests.first?.request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func accessLoginRedirectIsAccessDenied() async throws {
        let hub = AccessHub(access: nil, timeouts: roomy) { _, _, _ in
            .respond(status: 302, headers: ["Location": loginPage, "Server": "cloudflare"])
        }
        defer { hub.done() }
        let error = await #expect(throws: HubError.self) { try await hub.client.health() }
        #expect(error == .accessDenied)
        #expect(error?.errorDescription == "Cloudflare 门禁没放行这台设备，请重新配对")
        // Not the hub refusing the token (which would unpair), not an unreachable Neo.
        #expect(error?.needsPairing == false && error?.retryable == false)
        #expect(HubStatus.after(HubError.accessDenied) == .accessDenied)
        // The ping too.
        await #expect(throws: HubError.accessDenied) { try await hub.client.ping() }
    }

    @Test func aRedirectIsNeverFollowed() async throws {
        // A real redirect: the session would follow it, headers and all, to the login page's host.
        let elsewhere = stubHost()
        StubProtocol.register(host: elsewhere) { _, _, _ in .respond(status: 200, body: Data("<html>login</html>".utf8)) }
        defer { StubProtocol.remove(host: elsewhere) }
        let hub = AccessHub(timeouts: roomy) { _, _, _ in
            .redirect(status: 302, location: "https://\(elsewhere)/cdn-cgi/access/login/x")
        }
        defer { hub.done() }
        await #expect(throws: HubError.accessDenied) { try await hub.client.sync() }
        #expect(StubProtocol.requests(host: elsewhere).isEmpty)

        // The ping sent alongside a dictation follows none either, and a redirect does not count as the Neo answering.
        let request = DictationRequest(mode: .natural, autoStructured: true, durationSeconds: 1, client: .mac, clientVersion: "1.2.0")
        await #expect(throws: HubError.accessDenied) {
            try await hub.client.dictate(audio: Data(count: 100), type: .m4a, request: request)
        }
        #expect(StubProtocol.requests(host: elsewhere).isEmpty)
    }

    @Test func redirectDelegatesSayNo() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://hub.example.com/v1/health")!)
        let next = URLRequest(url: URL(string: loginPage)!)
        #expect(await RefuseRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: response(302),
                                                         newRequest: next) == nil)
        #expect(await ConnectionWatch().urlSession(session, task: task, willPerformHTTPRedirection: response(302),
                                                   newRequest: next) == nil)
    }

    @Test func accessPagesAreAccessDenied() async throws {
        let pages: [StubProtocol.Reply] = [
            // A wrong or rotated secret.
            .respond(status: 403, headers: ["Content-Type": "text/html", "Server": "cloudflare"],
                     body: Data("<html><title>Forbidden</title><a href=\"/cdn-cgi/access/logout\">Cloudflare Access</a></html>".utf8)),
            .respond(status: 403, headers: ["cf-access-domain": "hub.example.com"]),
            .respond(status: 403, headers: ["Set-Cookie": "CF_AppSession=abc; Path=/; Secure"]),
            // "Return 401 response for Service Auth policies".
            .respond(status: 401, headers: ["Server": "cloudflare", "CF-RAY": "8a1b2c3d4e5f-YYZ"]),
            .redirect(status: 302, location: loginPage),
        ]
        for page in pages {
            let hub = AccessHub(timeouts: roomy) { _, _, _ in page }
            defer { hub.done() }
            await #expect(throws: HubError.accessDenied, "\(page)") { try await hub.client.vocabulary() }
        }
    }

    @Test func otherRefusalsStayWhatTheyWere() async throws {
        // Cloudflare's firewall page: something on the way, not Access (and not the token).
        let waf = AccessHub(timeouts: roomy) { _, _, _ in
            .respond(status: 403, headers: ["Content-Type": "text/html", "Server": "cloudflare"],
                     body: Data("<html>Attention Required! | Cloudflare</html>".utf8))
        }
        defer { waf.done() }
        await #expect(throws: HubError.server(status: 403, body: nil)) { try await waf.client.sync() }

        // The hub's own refusal of the token still asks to pair again, through Access or not.
        let body = HubErrorBody(error: "这台设备已被移除，请重新配对", code: HubErrorCode.forbidden)
        let revoked = AccessHub(timeouts: roomy) { _, _, _ in
            .respond(status: 403, headers: ["Server": "cloudflare"], body: json(body))
        }
        defer { revoked.done() }
        let error = await #expect(throws: HubError.self) { try await revoked.client.health() }
        #expect(error?.needsPairing == true && error != .accessDenied)

        // A redirect that is not Access's: an error, followed nowhere.
        let moved = AccessHub(timeouts: roomy) { _, _, _ in .respond(status: 301, headers: ["Location": "https://example.com/"]) }
        defer { moved.done() }
        await #expect(throws: HubError.server(status: 301, body: nil)) { try await moved.client.health() }
    }

    @Test func refusalRules() {
        let empty = Data()
        #expect(HubAccessRefusal.matches(response(302, headers: ["Location": loginPage]), data: empty))
        #expect(HubAccessRefusal.matches(response(307, headers: ["Location": "/cdn-cgi/access/login/hub.example.com"]), data: empty))
        #expect(HubAccessRefusal.matches(response(303, headers: ["Location": "https://CLOUDFLAREACCESS.com/x"]), data: empty))
        // An answer from the login page's host, had a redirect been followed.
        #expect(HubAccessRefusal.matches(response(200, url: loginPage), data: Data("<html>".utf8)))
        #expect(!HubAccessRefusal.matches(response(302, headers: ["Location": "https://evilcloudflareaccess.com/"]), data: empty))
        #expect(!HubAccessRefusal.matches(response(302), data: empty))
        #expect(!HubAccessRefusal.matches(response(200), data: Data(#"{"ok":true}"#.utf8)))
        #expect(!HubAccessRefusal.matches(response(500, headers: ["cf-access-x": "1"]), data: empty))
        // A 401 not from Cloudflare (no Server / CF-RAY) and without its marks is not Access.
        #expect(!HubAccessRefusal.matches(response(401), data: empty))
        #expect(HubAccessRefusal.matches(response(401, headers: ["server": "Cloudflare"]), data: empty))
        // The hub's own error body is the hub's, whatever else comes with it.
        let hub = json(HubErrorBody(error: "这台设备的密钥不对，请重新配对", code: HubErrorCode.unauthorized))
        #expect(!HubAccessRefusal.matches(response(401, headers: ["Server": "cloudflare", "cf-access-x": "1"]), data: hub))
    }

    // MARK: What the device makes of it

    @Test func statusAndNotes() {
        let status = HubStatus.accessDenied
        #expect(status.text == "Cloudflare 门禁没放行")
        #expect(status.short == "Cloudflare 门禁没放行")
        #expect(status.detail == HubStatus.accessDeniedDetail)
        #expect(status.detail?.contains("没到 Neo") == true)
        #expect(status.isProblem && !status.covers && !status.recognizes)
        #expect(status.serviceFact == .accessDenied)
        #expect(HubDictation.fallbackNote(HubError.accessDenied) == "Cloudflare 门禁没放行，用本机处理")
        #expect(HubDictation.notRepolishedNote(HubError.accessDenied) == "Cloudflare 门禁没放行，没有重新整理")
        // What waits to be sent stays until the device is paired again.
        #expect(HubClient.flushStops(at: HubError.accessDenied))
    }

    @Test func theHubsOwnAccessCheck() async throws {
        // `requireAccess` on the hub, and Access in front of it off: the hub says so; pairing again would not help.
        let body = HubErrorBody(error: "Neo 只收经过 Cloudflare 门禁的请求，这次没有经过：检查 Cloudflare 上的 Access 设置",
                                code: HubErrorCode.accessRequired)
        let hub = AccessHub(timeouts: roomy) { _, _, _ in .respond(status: 403, body: json(body)) }
        defer { hub.done() }
        let error = await #expect(throws: HubError.self) { try await hub.client.health() }
        #expect(error == .server(status: 403, body: body))
        #expect(error?.needsPairing == false)
        #expect(error?.errorDescription == body.error)
        // The Neo answered: not "out of reach", not "Access stopped this device", and no new link asked for.
        let status = try #require(HubStatus.after(error!))
        #expect(status == .accessRequired)
        #expect(status.text == "Neo 只收经过 Cloudflare 门禁的请求")
        #expect(status.short == "Cloudflare 门禁没设好")
        #expect(status.detail == HubStatus.accessRequiredDetail && status.detail?.contains("重新配对没用") == true)
        #expect(status.isProblem && !status.covers && !status.recognizes)
        #expect(status.serviceFact == .accessRequired)
        #expect(HubDictation.fallbackNote(error!) == "Cloudflare 门禁没设好，用本机处理")
        #expect(HubDictation.notRepolishedNote(error!) == "Cloudflare 门禁没设好，没有重新整理")
        #expect(HubClient.flushStops(at: error!))
    }

    @Test func theProbeMeetingAccessEndsTheCallAtOnce() async throws {
        // Access answers the ping at once; its answer to the upload itself is slow (or never comes, or the edge drops
        // the connection mid-upload): the call is Access's refusal, not a Neo out of reach.
        let request = DictationRequest(mode: .natural, autoStructured: true, durationSeconds: 30, client: .mac, clientVersion: "1.2.0")
        for slow in [StubProtocol.Reply.hang, .fail(.networkConnectionLost, delay: 0.3)] {
            let hub = AccessHub { request, _, _ in
                request.url?.path == HubPath.ping ? .redirect(status: 302, location: loginPage) : slow
            }
            defer { hub.done() }
            let started = Date()
            await #expect(throws: HubError.accessDenied, "\(slow)") {
                try await hub.client.dictate(audio: Data(count: 200_000), type: .m4a, request: request)
            }
            // At once, next to the upload's own budget (tens of seconds for this recording).
            #expect(Date().timeIntervalSince(started) < 5, "\(slow)")
        }
        // A probe the hub itself answers with an error is no refusal: the call goes on as before (here: unreachable).
        let hub = AccessHub { request, _, _ in
            request.url?.path == HubPath.ping ? .respond(status: 500, body: json(HubErrorBody(error: "坏了", code: "internal"))) : .hang
        }
        defer { hub.done() }
        await #expect(throws: HubError.unreachable) {
            try await hub.client.dictate(audio: Data(count: 100), type: .m4a, request: request)
        }
    }
}
