import CryptoKit
import Foundation
import NeolessCore

// The hub's wire protocol (docs/hub.md): every request and response body, shared by the hub on the Neo and
// its clients (the Mac app, the iPhone app). This file is the one source of the field names; the contract in
// docs/hub.md describes the same shapes in prose.
//
// JSON is UTF-8 with camelCase keys. Optional fields that are nil are left out. Dates are ISO 8601 in UTC
// with milliseconds ("2026-10-09T08:30:00.123Z"); readers also accept them without the fraction. UUIDs are
// the usual 36-character strings (`UUID.uuidString`, upper case; any case is accepted).

// MARK: - Constants

/// Fixed values of the hub contract.
public enum Hub {
    /// A stand-in address for placeholders, previews and tests: nothing is ever sent to it. There is no default
    /// hub. A device learns its hub's address from the pairing link (or the address typed in Settings before a
    /// bare device token is pasted), and the hub prints links for the address `neoless-hub pair --server` gave it.
    public static let exampleServer = URL(string: "https://hub.example.com")!
    /// The hub listens on 127.0.0.1 only.
    public static let port = 18800
    /// The ASR worker, 127.0.0.1 only, called by the hub alone.
    public static let asrWorkerPort = 18801
    /// The hub's data folder in ~/Library/Application Support (0700, files 0600).
    public static let dataFolderName = "neoless-hub"
    /// The worker's shared secret, in the hub's data folder (0600).
    public static let workerSecretFileName = "worker-secret"
    /// The app's bundle identifier in this source (Resources/Info.plist). A build may carry another one that ends
    /// in ".neoless": `scripts/build-app.sh` keeps the identifier of the neoless already installed, so an update
    /// stays the same app to macOS (its permissions, settings and Keychain item).
    public static let bundleID = "app.neoless"
    /// Keychain service of the device token on the Mac and the iPhone (kSecClassGenericPassword): the running
    /// app's bundle identifier and ".hub".
    public static var keychainService: String { keychainService(bundleID: Bundle.main.bundleIdentifier) }
    /// A process that is not a neoless app bundle (the hub's command line, a debug build, a test run) gets the
    /// service of `bundleID`.
    public static func keychainService(bundleID: String?) -> String {
        let id = bundleID.flatMap { $0.hasSuffix(".neoless") ? $0 : nil } ?? Hub.bundleID
        return id + ".hub"
    }
    /// The iPhone app and its keyboard share settings, the token and results through this App Group.
    public static let appGroup = "group." + bundleID
    /// Largest audio body the hub takes (413 above).
    public static let maxAudioBytes = 12 * 1024 * 1024
    /// Largest JSON body the hub takes (413 above).
    public static let maxJSONBytes = 256 * 1024
    /// Largest `PUT /v1/vocabulary` body: a whole dictionary at its limits (`Vocabulary.maxWords` words of up to
    /// `Vocabulary.maxWordLength` characters, about 3 bytes each in Chinese) is more than `maxJSONBytes`.
    public static let maxVocabularyJSONBytes = 1024 * 1024
    /// Longest text the hub keeps for one dictation (`/v1/polish`, `…/edit`, the local transcript): far more than
    /// ten minutes of speech. Longer is 413.
    public static let maxTextCharacters = 20_000
    /// Longest `appName`, `bundleID` or `clientVersion` (413 above).
    public static let maxNameCharacters = 200
    /// Requests per device per minute, counted twice over: once for the dictation calls (`/v1/dictations`,
    /// `/v1/polish`, `…/repolish`) and once for everything else, so background syncing never uses up what a
    /// dictation needs (429 above).
    public static let requestsPerMinute = 30
    /// Most `wrongs` one `POST /v1/learning/forget` takes (400 above).
    public static let maxForgetWrongs = 1_000
    /// Largest `X-Neoless-Request` value a client sends. Proxies limit header size (Cloudflare, aiohttp's
    /// 8190 bytes), so `DictationRequest.headerValue()` leaves the local transcript out when it would not fit.
    public static let maxRequestHeaderBytes = 8 * 1024
    /// Largest `X-Hints` value the hub sends the worker (aiohttp refuses header fields over 8190 bytes).
    public static let maxHintsHeaderBytes = 6 * 1024
    /// `limit` of `GET /v1/history`: the default and the most one page holds.
    public static let defaultHistoryLimit = 50, maxHistoryLimit = 200
    /// A device asks for the speech model to be got ready (`POST /v1/warm`) at most this often: the model is then in
    /// memory, or on its way, for the next ten minutes (the worker unloads it after ten idle minutes), so asking
    /// again sooner only adds requests.
    public static let warmInterval: TimeInterval = 30
    /// The hub passes at most one warm-up per device to its worker this often, whatever the device sends: a burst of
    /// presses (or a device that does not keep to `warmInterval`) never becomes a burst of model loads. Shorter than
    /// `warmInterval`, so a device that keeps to it is never turned away because its request arrived a little early.
    public static let warmSpacing: TimeInterval = 10
}

public enum HubHeader {
    /// base64url(JSON `DictationRequest`) on `POST /v1/dictations`.
    public static let request = "X-Neoless-Request"
    /// The worker's shared secret on hub → worker calls.
    public static let worker = "X-Neoless-Worker"
    /// base64url(JSON [String]) recognition hints on `POST /recognize`.
    public static let hints = "X-Hints"
    /// The speech model a dictation asks for (`HubASRModel`: "auto", "large" or "small") on `POST /recognize`.
    public static let model = "X-Model"
    /// A Cloudflare Access service token (`HubAccess`), on every request of a device whose pairing has one, so
    /// Cloudflare lets it through to the Neo (docs/hub.md, "Access 双重锁").
    public static let accessClientID = "CF-Access-Client-Id"
    public static let accessClientSecret = "CF-Access-Client-Secret"
    /// What Cloudflare Access adds to a request it let through. The hub only looks whether it is there, and only
    /// when `settings.json` says `requireAccess`.
    public static let accessJWT = "Cf-Access-Jwt-Assertion"
}

/// Request paths. `{id}` is a dictation's `id`.
public enum HubPath {
    public static let ping = "/v1/ping"
    public static let health = "/v1/health"
    public static let dictations = "/v1/dictations"
    public static let polish = "/v1/polish"
    public static let learning = "/v1/learning"
    public static let learningObservations = "/v1/learning/observations"
    public static let learningForget = "/v1/learning/forget"
    public static let vocabulary = "/v1/vocabulary"
    public static let habits = "/v1/habits"
    public static let history = "/v1/history"
    public static let sync = "/v1/sync"
    public static let warm = "/v1/warm"
    public static func repolish(_ id: UUID) -> String { "/v1/dictations/\(id.uuidString)/repolish" }
    public static func edit(_ id: UUID) -> String { "/v1/dictations/\(id.uuidString)/edit" }
    public static func historyItem(_ id: UUID) -> String { "/v1/history/\(id.uuidString)" }

    /// The ASR worker's paths.
    public static let workerHealth = "/health"
    public static let workerRecognize = "/recognize"
    public static let workerWarm = "/warm"
}

// MARK: - Encoding

/// base64url without padding (RFC 4648 §5), as the request header, the hints header and device tokens use it.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts the text with or without padding; nil for anything outside the base64url alphabet.
    public static func decode(_ text: String) -> Data? {
        var body = text.trimmingCharacters(in: .whitespaces)
        while body.hasSuffix("=") { body.removeLast() }
        guard body.unicodeScalars.allSatisfy(isAlphabet), body.count % 4 != 1 else { return nil }
        var b64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }

    static func isAlphabet(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
        default: return false
        }
    }
}

/// The JSON coders every hub body goes through.
public enum HubJSON {
    private static let seconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: TimeZone(secondsFromGMT: 0)!)

    /// "2026-10-09T08:30:00.123Z": UTC, always three fraction digits, the date rounded to the millisecond.
    public static func string(from date: Date) -> String {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        let whole = (millis / 1000).rounded(.down)
        let fraction = Int(millis - whole * 1000)
        let base = seconds.format(Date(timeIntervalSince1970: whole))   // "2026-10-09T08:30:00Z"
        return String(base.dropLast()) + String(format: ".%03dZ", fraction)
    }

    /// Reads what `string(from:)` writes, and any other ISO 8601 time with or without a fraction or offset.
    public static func date(from text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("Z"), let dot = text.lastIndex(of: "."),
           let base = try? seconds.parse(String(text[..<dot]) + "Z") {
            let digits = text[text.index(after: dot)..<text.index(before: text.endIndex)]
            guard (1...9).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else { return nil }
            // Milliseconds, as `string(from:)` and `rounded` keep them.
            let millis = (Double(value) / pow(10, Double(digits.count)) * 1000).rounded()
            return Date(timeIntervalSince1970: (base.timeIntervalSince1970 * 1000 + millis) / 1000)
        }
        if let date = try? seconds.parse(text) { return date }
        let other = ISO8601DateFormatter()
        other.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = other.date(from: text) { return date }
        other.formatOptions = [.withInternetDateTime]
        return other.date(from: text)
    }

    /// The date as the protocol carries it: rounded to the millisecond, so it survives a round trip unchanged.
    public static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(string(from: date))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "不是 ISO 8601 时间：\(text)")
            }
            return date
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }
}

// MARK: - Small string-backed values

/// Which kind of device made a request: `mac` or `ios`. Values this build does not know are kept as they are.
public struct HubClientKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let mac: HubClientKind = "mac"
    public static let ios: HubClientKind = "ios"

    /// The kind of device this code runs on.
    public static var current: HubClientKind {
        #if os(iOS)
        return .ios
        #else
        return .mac
        #endif
    }
}

/// What recognised the speech: the hub's Qwen3-ASR, or the device's own recognizer (`local`, when the hub
/// heard nothing and used `localTranscript`, and always for `POST /v1/polish`).
public struct HubRecognizer: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let qwen3ASR: HubRecognizer = "qwen3-asr"
    public static let local: HubRecognizer = "local"
}

/// The audio formats `POST /v1/dictations` takes.
public enum HubAudioType: String, Codable, CaseIterable, Sendable {
    /// AAC-LC in an MPEG-4 container (.m4a): what clients send.
    case m4a = "audio/mp4"
    /// 16-bit PCM WAV: the fallback when AAC encoding fails.
    case wav = "audio/wav"
    /// Core Audio Format (iOS recordings).
    case caf = "audio/x-caf"

    /// The type of a `Content-Type` header: parameters and case are ignored, common aliases accepted.
    public init?(contentType: String) {
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/mp4a-latm": self = .m4a
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": self = .wav
        case "audio/x-caf", "audio/caf": self = .caf
        default: return nil
        }
    }

    public var fileExtension: String {
        switch self {
        case .m4a: return "m4a"
        case .wav: return "wav"
        case .caf: return "caf"
        }
    }
}

// MARK: - Errors

/// The body of every error answer: `{"error": "中文", "code": "snake_case", "retryable": bool}`.
public struct HubErrorBody: Codable, Equatable, Sendable, Error {
    /// Plain Chinese for the user.
    public var error: String
    /// For programs: one of `HubErrorCode`.
    public var code: String
    /// Whether the same request may succeed if sent again later.
    public var retryable: Bool

    public init(error: String, code: String, retryable: Bool = false) {
        self.error = error; self.code = code; self.retryable = retryable
    }
}

/// The `code` values of `HubErrorBody`.
public enum HubErrorCode {
    public static let badRequest = "bad_request"              // 400: malformed body, header or query
    public static let unauthorized = "unauthorized"           // 401: no token, or not a paired device's
    public static let forbidden = "forbidden"                 // 403: the device was revoked
    public static let notFound = "not_found"                  // 404: no such dictation or route
    public static let conflict = "revision_conflict"          // 409: vocabulary changed since `expectedRevision`
    public static let tooLarge = "too_large"                  // 413: audio over 12 MB, JSON over 256 KB
    public static let unsupportedMedia = "unsupported_media"  // 415: audio type not taken
    public static let rateLimited = "rate_limited"            // 429: over 30 requests a minute
    public static let decodeFailed = "decode_failed"          // 422: the audio could not be decoded
    public static let asrUnavailable = "asr_unavailable"      // 503: the ASR worker is down (retryable)
    public static let polishFailed = "polish_failed"          // 503: …/repolish got no answer from ChatGPT; text unchanged
    public static let internalError = "internal"              // 500
    /// 403: the hub takes only requests Cloudflare Access let through (`requireAccess`), and this one did not come
    /// through it. Not the device's fault: re-pairing does not help, Access in front of the hub has to be fixed.
    public static let accessRequired = "access_required"
}

/// A request or link that does not follow the protocol.
public enum HubProtocolError: LocalizedError, Equatable, Sendable {
    /// The `X-Neoless-Request` header is missing, not base64url or not a `DictationRequest`.
    case badRequestHeader
    /// The `X-Neoless-Request` header would be too long even without the local transcript.
    case requestHeaderTooLarge
    /// Not a `neoless://pair` link.
    case notPairLink
    /// The link's server is not an https address (http only for this Mac itself).
    case badServer
    /// The link's device token is missing or malformed.
    case badToken
    /// What was pasted to pair is neither a `neoless://pair` link nor a device token.
    case notPairingText
    /// A bare device token was pasted and no server address was given: there is no default hub to pair it with.
    case noServer
    /// The link's Cloudflare Access credentials are incomplete or malformed.
    case badAccess

    public var errorDescription: String? {
        switch self {
        case .badRequestHeader: return "听写请求的格式不对"
        case .requestHeaderTooLarge: return "听写请求太长"
        case .notPairLink: return "这不是 neoless 配对链接"
        case .badServer: return "配对链接里的服务器地址不对"
        case .badToken: return "配对链接里的设备密钥不对"
        case .notPairingText: return "这不是配对链接，也不是设备密钥"
        case .noServer: return "只有设备密钥还不够：先填服务器地址，或者粘贴 Neo 上生成的完整配对链接"
        case .badAccess: return "配对链接里的 Cloudflare 门禁凭据不完整或不对"
        }
    }
}

// MARK: - Bodies

/// `GET /v1/ping`, and any `{"ok": true}` answer (`DELETE /v1/history/{id}`).
public struct HubOK: Codable, Equatable, Sendable {
    public var ok: Bool
    public init(ok: Bool = true) { self.ok = ok }
}

/// `GET /v1/health`.
public struct HubHealth: Codable, Equatable, Sendable {
    public struct ASR: Codable, Equatable, Sendable {
        public var ready: Bool
        /// The model a dictation gets when it asks for none (`HubASRModel.auto`), right now.
        public var model: String
        /// The Neo's large model (`HubASRModel.large`). Older hubs and workers leave these three out.
        public var largeModel: String?
        /// Its small one (`HubASRModel.small`); left out when the Neo runs a single model, which then answers
        /// whatever a dictation asks for.
        public var smallModel: String?
        /// Which of the two `auto` uses right now: `.large`, or `.small` while the Neo is too busy for the large one.
        public var autoUses: HubASRModel?

        public init(ready: Bool, model: String, largeModel: String? = nil, smallModel: String? = nil,
                    autoUses: HubASRModel? = nil) {
            self.ready = ready; self.model = model
            self.largeModel = largeModel; self.smallModel = smallModel; self.autoUses = autoUses
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ready = try c.decode(Bool.self, forKey: .ready)
            model = try c.decode(String.self, forKey: .model)
            largeModel = try c.decodeIfPresent(String.self, forKey: .largeModel)
            smallModel = try c.decodeIfPresent(String.self, forKey: .smallModel)
            // A value this version does not know is no reason to fail the whole health answer.
            let said = (try? c.decodeIfPresent(String.self, forKey: .autoUses)) ?? nil
            autoUses = said.flatMap(HubASRModel.init(rawValue:))
        }
    }

    public struct ChatGPT: Codable, Equatable, Sendable {
        public var ready: Bool
        /// Masked: "a***@example.com".
        public var account: String?
        /// Why it cannot polish, in plain Chinese.
        public var problem: String?
        public init(ready: Bool, account: String? = nil, problem: String? = nil) {
            self.ready = ready; self.account = account; self.problem = problem
        }
    }

    public var ok: Bool
    public var version: String
    public var asr: ASR
    public var chatgpt: ChatGPT
    /// The name the asking device was paired under.
    public var device: String
    /// The hub's 整理超时 floor in seconds (settings.json `polishTimeout`, 4–30): how long its ChatGPT polish may
    /// take at least, so devices size their budgets with it. Older hubs leave it out (10).
    public var polishTimeout: Double?

    public init(ok: Bool = true, version: String, asr: ASR, chatgpt: ChatGPT, device: String, polishTimeout: Double? = nil) {
        self.ok = ok; self.version = version; self.asr = asr; self.chatgpt = chatgpt; self.device = device
        self.polishTimeout = polishTimeout
    }
}

/// What `POST /v1/dictations` carries in its `X-Neoless-Request` header, as base64url(JSON).
/// Which of the Neo's speech models a device asks for. `auto`: the large one, the small one while the Neo
/// is too busy for it (the worker decides). `large` / `small`: that one, whatever the Neo is doing.
public enum HubASRModel: String, Codable, CaseIterable, Sendable {
    case auto, large, small

    /// A choice this version does not know (a newer device's) reads as `auto`, as the worker reads an
    /// `X-Model` it does not know: it must not make the whole request unreadable, and so refuse the dictation.
    public init(from decoder: Decoder) throws {
        let said = try? decoder.singleValueContainer().decode(String.self)
        self = said.flatMap(Self.init(rawValue:)) ?? .auto
    }
}

public struct DictationRequest: Codable, Equatable, Sendable {
    /// The mode chosen on the device (before AI apps turn 自然整理 into 结构化).
    public var mode: DictationMode
    /// Whether AI apps get 结构化 (`DictationMode.effective`).
    public var autoStructured: Bool
    /// The app the text goes into.
    public var appName: String?
    public var bundleID: String?
    /// The recognition language, "zh-CN".
    public var locale: String
    /// What the device's own recognizer heard, used when the hub hears nothing. Left out when the header
    /// would get too long (`headerValue()`); the device then keeps it for its own fallback: when the hub's
    /// `raw` comes back empty, it sends it to `POST /v1/polish` (`polishRequest(text:)`).
    public var localTranscript: String?
    public var durationSeconds: Double
    /// One per recording, shared with `POST /v1/polish`: the hub works on a recording once and keeps one history
    /// entry for it. Sending it again returns that result, waiting for it when it is still being made. A result
    /// with an empty `raw` is not kept, so the device's own transcript can follow under the same id.
    public var clientRecordingID: UUID
    public var client: HubClientKind
    public var clientVersion: String
    /// The speech model the device asks for; left out (older devices) means `auto`, and so does a value this
    /// version does not know (`HubASRModel.init(from:)`).
    public var asrModel: HubASRModel?

    public init(mode: DictationMode, autoStructured: Bool, appName: String? = nil, bundleID: String? = nil,
                locale: String = "zh-CN", localTranscript: String? = nil, durationSeconds: Double,
                clientRecordingID: UUID = UUID(), client: HubClientKind = .current, clientVersion: String,
                asrModel: HubASRModel? = nil) {
        self.mode = mode; self.autoStructured = autoStructured; self.appName = appName; self.bundleID = bundleID
        self.locale = locale; self.localTranscript = localTranscript; self.durationSeconds = durationSeconds
        self.clientRecordingID = clientRecordingID; self.client = client; self.clientVersion = clientVersion
        self.asrModel = asrModel
    }

    /// The mode the hub polishes in.
    public var effectiveMode: DictationMode {
        DictationMode.effective(mode, autoStructured: autoStructured, bundleID: bundleID, appName: appName)
    }

    /// The `X-Neoless-Request` value: base64url(JSON), at most `Hub.maxRequestHeaderBytes`. A local transcript
    /// that would make it longer is left out (never cut: half a transcript is worse than none).
    public func headerValue(limit: Int = Hub.maxRequestHeaderBytes) throws -> String {
        let full = Base64URL.encode(try HubJSON.encode(self))
        if full.utf8.count <= limit { return full }
        var shorter = self
        shorter.localTranscript = nil
        let value = Base64URL.encode(try HubJSON.encode(shorter))
        guard value.utf8.count <= limit else { throw HubProtocolError.requestHeaderTooLarge }
        return value
    }

    /// The `POST /v1/polish` for this recording's own transcript, sent when the hub heard nothing (`raw` came
    /// back empty) because the transcript was left out of the header. Same recording, same `clientRecordingID`:
    /// the hub keeps no empty result under it.
    public func polishRequest(text: String) -> PolishRequest {
        PolishRequest(text: text, mode: mode, autoStructured: autoStructured, appName: appName, bundleID: bundleID,
                      clientRecordingID: clientRecordingID, client: client, clientVersion: clientVersion,
                      durationSeconds: durationSeconds)
    }

    /// Reads an `X-Neoless-Request` value.
    public init(headerValue: String) throws {
        guard let data = Base64URL.decode(headerValue),
              let request = try? HubJSON.decode(DictationRequest.self, from: data),
              request.durationSeconds.isFinite, request.durationSeconds >= 0
        else { throw HubProtocolError.badRequestHeader }
        self = request
    }
}

/// Why a result is the original text and not polished: "已输入原文" / "整理超时".
public struct HubFallback: Codable, Equatable, Sendable {
    public var title: String
    public var reason: String
    public init(title: String, reason: String) { self.title = title; self.reason = reason }
}

/// Where the time went, in milliseconds.
public struct HubTimings: Codable, Equatable, Sendable {
    public var decodeMs: Int
    public var asrMs: Int
    public var polishMs: Int
    public var totalMs: Int
    public init(decodeMs: Int = 0, asrMs: Int = 0, polishMs: Int = 0, totalMs: Int = 0) {
        self.decodeMs = decodeMs; self.asrMs = asrMs; self.polishMs = polishMs; self.totalMs = totalMs
    }
}

/// One dictation as the hub returns it (`POST /v1/dictations`, `/v1/polish`, `…/repolish`, `…/edit`).
public struct DictationResult: Codable, Equatable, Identifiable, Sendable {
    /// The hub's id for this dictation (history, repolish, edit).
    public var id: UUID
    public var clientRecordingID: UUID
    /// What was recognised.
    public var raw: String
    /// What to type: polished, or `raw` with confirmed corrections when polishing did not happen.
    public var text: String
    /// The mode actually used (after AI apps turned 自然整理 into 结构化).
    public var mode: DictationMode
    public var polished: Bool
    /// Set when the mode polishes but `text` is not polished.
    public var fallback: HubFallback?
    public var recognizer: HubRecognizer
    public var timings: HubTimings
    public var createdAt: Date

    public init(id: UUID = UUID(), clientRecordingID: UUID, raw: String, text: String, mode: DictationMode, polished: Bool,
                fallback: HubFallback? = nil, recognizer: HubRecognizer, timings: HubTimings = HubTimings(),
                createdAt: Date = HubJSON.rounded(Date())) {
        self.id = id; self.clientRecordingID = clientRecordingID; self.raw = raw; self.text = text; self.mode = mode
        self.polished = polished; self.fallback = fallback; self.recognizer = recognizer; self.timings = timings
        self.createdAt = createdAt
    }
}

/// `POST /v1/polish`: text the device recognised itself, to polish (or to keep, in 原样转写) and save.
public struct PolishRequest: Codable, Equatable, Sendable {
    public var text: String
    public var mode: DictationMode
    public var autoStructured: Bool
    public var appName: String?
    public var bundleID: String?
    /// Idempotent and shared with `DictationRequest.clientRecordingID`: one job and one history entry per id.
    public var clientRecordingID: UUID
    /// For the history list. Optional: older clients leave them out.
    public var client: HubClientKind?
    public var clientVersion: String?
    public var durationSeconds: Double?

    public init(text: String, mode: DictationMode, autoStructured: Bool, appName: String? = nil, bundleID: String? = nil,
                clientRecordingID: UUID = UUID(), client: HubClientKind? = .current, clientVersion: String? = nil,
                durationSeconds: Double? = nil) {
        self.text = text; self.mode = mode; self.autoStructured = autoStructured; self.appName = appName
        self.bundleID = bundleID; self.clientRecordingID = clientRecordingID; self.client = client
        self.clientVersion = clientVersion; self.durationSeconds = durationSeconds
    }

    public var effectiveMode: DictationMode {
        DictationMode.effective(mode, autoStructured: autoStructured, bundleID: bundleID, appName: appName)
    }
}

/// `POST /v1/warm`: a press became a dictation; the speech model it will use is got ready while the user is still
/// speaking, so the recording does not wait for it to load. Answered at once with `{"ok": true}`.
public struct WarmRequest: Codable, Equatable, Sendable {
    /// The model the dictation will ask for (`DictationRequest.asrModel`): left out means `auto`, whichever the Neo
    /// uses right now.
    public var asrModel: HubASRModel?
    public init(asrModel: HubASRModel? = nil) { self.asrModel = asrModel == .auto ? nil : asrModel }
}

/// `POST /v1/dictations/{id}/repolish`. No mode: the dictation's own (原样转写 is polished as 自然整理).
public struct RepolishRequest: Codable, Equatable, Sendable {
    public var mode: DictationMode?
    public init(mode: DictationMode? = nil) { self.mode = mode }
}

/// `POST /v1/dictations/{id}/edit`: the final text after the user changed it.
public struct EditRequest: Codable, Equatable, Sendable {
    public var text: String
    /// False: only keep the text, learn nothing from the change (a device that sends what it learned itself as
    /// observations, as the Mac does). Left out: the hub learns from the change.
    public var learn: Bool?
    public init(text: String, learn: Bool? = nil) { self.text = text; self.learn = learn }
}

public struct EditResponse: Codable, Equatable, Sendable {
    public var result: DictationResult
    /// The corrections learned from this edit (`CorrectionExtractor`).
    public var learned: [CorrectionPair]
    public init(result: DictationResult, learned: [CorrectionPair] = []) { self.result = result; self.learned = learned }
}

/// `POST /v1/learning/observations`: corrections the Mac saw the user make in another app.
public struct LearningObservations: Codable, Equatable, Sendable {
    public var pairs: [CorrectionPair]
    public var dictationID: UUID?
    /// The device's own id for this observation. A hub that knows ids answers one it has seen with the answer
    /// it gave then and counts nothing twice, so a device may send again what it got no answer for.
    public var id: UUID?
    /// `"repeated"`: every pair here is a swap the device saw the user make in two dictations, which does not
    /// sound alike (`LearnedCorrection.Kind.repeated`). The hub learns such a pair as a hint for the model only,
    /// after checking it against what no rule allows (`CorrectionExtractor.isRepeatable`). Left out: corrections
    /// judged as recognition errors, as before. A hub from before this field ignores it and judges the pairs
    /// as recognition errors, which they are not: it takes none of them.
    public var kind: LearnedCorrection.Kind?
    public init(pairs: [CorrectionPair], dictationID: UUID? = nil, id: UUID? = nil, kind: LearnedCorrection.Kind? = nil) {
        self.pairs = pairs; self.dictationID = dictationID; self.id = id; self.kind = kind
    }
}

/// `POST /v1/learning/forget`: forgets every pair with one of these `wrong`s, as `DELETE /v1/learning?wrong=…` does
/// one (清空 on a device). Answered with the list afterwards.
public struct LearningForget: Codable, Equatable, Sendable {
    public var wrongs: [String]
    public init(wrongs: [String]) { self.wrongs = wrongs }
}

public struct LearningObservationsResponse: Codable, Equatable, Sendable {
    /// How many pairs the learning book took: learned, counted again, or counted down.
    public var accepted: Int
    /// The pairs it did not take (not a term fix by its rules, more than it takes at once, the day's new
    /// corrections used up). Left out by a hub from before it said so.
    public var refused: [CorrectionPair]?
    /// Words it put in its dictionary without learning a mapping (`CorrectionExtractor.Strength.termOnly`).
    public var terms: [String]?
    /// The observation's `id`, from a hub that remembers them (`LearningObservations.id`).
    public var id: UUID?
    public init(accepted: Int, refused: [CorrectionPair]? = nil, terms: [String]? = nil, id: UUID? = nil) {
        self.accepted = accepted; self.refused = refused; self.terms = terms; self.id = id
    }
}

/// One learned correction.
public struct LearningEntry: Codable, Equatable, Sendable {
    public var wrong: String
    public var right: String
    public var count: Int
    public var lastSeen: Date
    /// `"repeated"` for a swap made twice, which is only a hint for the model; left out for a correction
    /// learned as a recognition error. A device from before this field judges every entry as a recognition
    /// error and so uses none of these.
    public var kind: LearnedCorrection.Kind?
    public init(wrong: String, right: String, count: Int, lastSeen: Date, kind: LearnedCorrection.Kind? = nil) {
        self.wrong = wrong; self.right = right; self.count = count; self.lastSeen = lastSeen; self.kind = kind
    }
    public var pair: CorrectionPair { CorrectionPair(wrong: wrong, right: right) }
}

/// `GET /v1/learning`, and the answer to `DELETE /v1/learning?wrong=…` (the list afterwards).
public struct LearningList: Codable, Equatable, Sendable {
    public var pairs: [LearningEntry]
    public init(pairs: [LearningEntry] = []) { self.pairs = pairs }
}

/// `GET /v1/vocabulary`, and the answer to `PUT /v1/vocabulary` (the dictionary afterwards).
public struct VocabularySnapshot: Codable, Equatable, Sendable {
    /// The whole dictionary, the user's order (learned terms mixed in).
    public var words: [String]
    /// The words in it only because learning added them.
    public var learned: [String]
    /// Changes with every change of `words`; opaque.
    public var revision: String
    /// Changes only when the hub's dictionary starts over (a new data folder, or vocabulary.json that could not
    /// be read and is back to the defaults): a device's "words at the last sync" belong to an older one then, and
    /// a word missing now was not removed by anyone. Opaque; older hubs leave it out.
    public var generation: String?
    public init(words: [String], learned: [String] = [], revision: String, generation: String? = nil) {
        self.words = words; self.learned = learned; self.revision = revision; self.generation = generation
    }
}

/// `PUT /v1/vocabulary`: the whole new list. 409 when the dictionary changed since `expectedRevision`.
public struct VocabularyUpdate: Codable, Equatable, Sendable {
    public var words: [String]
    public var expectedRevision: String
    public init(words: [String], expectedRevision: String) { self.words = words; self.expectedRevision = expectedRevision }
}

/// One `GET /v1/history` item: a `DictationResult` with three more fields, all in one JSON object.
public struct HistoryItem: Codable, Equatable, Identifiable, Sendable {
    public var result: DictationResult
    public var appName: String?
    public var client: HubClientKind?
    /// The user changed the text afterwards (`…/edit`).
    public var edited: Bool

    public var id: UUID { result.id }

    public init(result: DictationResult, appName: String? = nil, client: HubClientKind? = nil, edited: Bool = false) {
        self.result = result; self.appName = appName; self.client = client; self.edited = edited
    }

    private enum ExtraKeys: String, CodingKey { case appName, client, edited }

    public init(from decoder: Decoder) throws {
        result = try DictationResult(from: decoder)
        let c = try decoder.container(keyedBy: ExtraKeys.self)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        client = try c.decodeIfPresent(HubClientKind.self, forKey: .client)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        try result.encode(to: encoder)
        var c = encoder.container(keyedBy: ExtraKeys.self)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(client, forKey: .client)
        try c.encode(edited, forKey: .edited)
    }
}

/// `GET /v1/history?limit=50&before=…`, newest first.
public struct HistoryPage: Codable, Equatable, Sendable {
    public var items: [HistoryItem]
    /// Pass as `before` for the next (older) page; nil on the last page. Opaque to clients.
    public var nextBefore: String?
    public init(items: [HistoryItem], nextBefore: String? = nil) { self.items = items; self.nextBefore = nextBefore }
}

/// Settings the hub keeps for every device.
public struct HubSettings: Codable, Equatable, Sendable {
    public var autoStructured: Bool
    public init(autoStructured: Bool = true) { self.autoStructured = autoStructured }
}

/// `GET /v1/habits`, and the answer to `PUT /v1/habits` (the list afterwards): 我的习惯, the user's own writing
/// preferences, which the hub gives every polish (`PolishPrompt.habitsSection`).
public struct HabitsSnapshot: Codable, Equatable, Sendable {
    /// In the user's order, cleaned (`Habits.normalized`): at most `Habits.maxItems`, each at most
    /// `Habits.maxLength` characters on one line.
    public var items: [String]
    /// Changes with every change of `items`; opaque.
    public var revision: String
    /// Changes only when the hub's habits start over (a new data folder, or habits.json that was lost or could
    /// not be read): the list is then one nobody stored there, and a device's "habits at the last sync" belong
    /// to an older one, so its own habits are sent again instead of being taken for deleted. Opaque; left out
    /// by a hub from before it.
    public var generation: String?
    public init(items: [String] = [], revision: String, generation: String? = nil) {
        self.items = items; self.revision = revision; self.generation = generation
    }
}

/// `PUT /v1/habits`: the whole new list. With `expectedRevision`, 409 when the list changed since; without
/// it the list is replaced whatever it was.
public struct HabitsUpdate: Codable, Equatable, Sendable {
    public var items: [String]
    public var expectedRevision: String?
    public init(items: [String], expectedRevision: String? = nil) {
        self.items = items; self.expectedRevision = expectedRevision
    }
}

/// `GET /v1/sync`: what a device keeps for when it cannot reach the hub.
public struct SyncSnapshot: Codable, Equatable, Sendable {
    public var vocabulary: VocabularySnapshot
    public var learning: LearningList
    public var settings: HubSettings
    /// 我的习惯 as the hub has them. Always there from a hub that keeps habits (an empty list when the user has
    /// none); left out by a hub from before them, which is how a device knows not to send its own.
    public var habits: HabitsSnapshot?
    public init(vocabulary: VocabularySnapshot, learning: LearningList, settings: HubSettings, habits: HabitsSnapshot? = nil) {
        self.vocabulary = vocabulary; self.learning = learning; self.settings = settings; self.habits = habits
    }
}

// MARK: - ASR worker (hub → worker, 127.0.0.1 only)

/// `POST http://127.0.0.1:18801/warm` (worker 1.4): answered at once, the model loads in the background.
public struct ASRWorkerWarm: Codable, Equatable, Sendable {
    public var ok: Bool
    /// The model a recognition with the same `X-Model` would use now.
    public var model: String?
    /// That model was in memory as the request arrived: nothing loads.
    public var loaded: Bool
    /// A warm-up job waits or runs (this one, or one before it that is not done).
    public var warming: Bool?

    public init(ok: Bool = true, model: String? = nil, loaded: Bool, warming: Bool? = nil) {
        self.ok = ok; self.model = model; self.loaded = loaded; self.warming = warming
    }
}

/// `GET http://127.0.0.1:18801/health`.
public struct ASRWorkerHealth: Codable, Equatable, Sendable {
    public var ok: Bool
    /// The model `X-Model: auto` (or no `X-Model`) gets right now.
    public var model: String
    /// A model is in memory (it is unloaded after 10 idle minutes and loaded again on the next request).
    public var loaded: Bool
    /// Requests queued or being recognised (at most 8).
    public var pending: Int?
    /// Why the last model load failed (when `ok` is false); the next request tries again.
    public var problem: String?
    /// What `X-Model: large` gets. Workers before 1.3 leave these three out.
    public var largeModel: String?
    /// What `X-Model: small` gets; left out when the worker runs a single model.
    public var smallModel: String?
    /// "large" or "small": which of the two `auto` uses right now.
    public var autoUses: String?

    public init(ok: Bool, model: String, loaded: Bool, pending: Int? = nil, problem: String? = nil,
                largeModel: String? = nil, smallModel: String? = nil, autoUses: String? = nil) {
        self.ok = ok; self.model = model; self.loaded = loaded; self.pending = pending; self.problem = problem
        self.largeModel = largeModel; self.smallModel = smallModel; self.autoUses = autoUses
    }

    /// What `GET /v1/health` tells devices about recognition.
    public var forDevices: HubHealth.ASR {
        HubHealth.ASR(ready: ok, model: model, largeModel: largeModel, smallModel: smallModel,
                      autoUses: autoUses.flatMap(HubASRModel.init(rawValue:)))
    }
}

/// `POST http://127.0.0.1:18801/recognize`.
public struct ASRWorkerResult: Codable, Equatable, Sendable {
    /// `ok`, `empty` (no text) or `no_speech` (silence).
    public struct Status: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        public static let ok: Status = "ok"
        public static let empty: Status = "empty"
        public static let noSpeech: Status = "no_speech"
    }

    public var raw: String
    public var status: Status
    /// Recognition alone (not resampling, loading or queueing).
    public var asrMs: Int
    public var model: String
    /// Loading the model for this request (0 when it was already loaded).
    public var loadMs: Int?
    /// Waiting behind other requests.
    public var queueMs: Int?
    public var audioSeconds: Double?
    /// How many stretches of the recording were recognised on their own: more than 1 when it switched between
    /// Chinese and English, or went on in one of them for over 30 seconds (0 for silence). Workers before 1.3
    /// leave it out.
    public var segments: Int?
    public init(raw: String, status: Status, asrMs: Int, model: String,
                loadMs: Int? = nil, queueMs: Int? = nil, audioSeconds: Double? = nil, segments: Int? = nil) {
        self.raw = raw; self.status = status; self.asrMs = asrMs; self.model = model
        self.loadMs = loadMs; self.queueMs = queueMs; self.audioSeconds = audioSeconds; self.segments = segments
    }
}

/// The worker's `X-Hints` header: base64url(JSON [String]).
public enum ASRHints {
    /// The hints, most important first, cut from the end until the value fits in `limit` bytes.
    public static func headerValue(_ hints: [String], limit: Int = Hub.maxHintsHeaderBytes) -> String {
        var kept = hints
        while true {
            let value = Base64URL.encode((try? HubJSON.encode(kept)) ?? Data("[]".utf8))
            if value.utf8.count <= limit || kept.isEmpty { return value }
            // Drop about a tenth at a time, at least one.
            kept.removeLast(max(1, kept.count / 10))
        }
    }

    public static func decode(_ value: String) -> [String]? {
        Base64URL.decode(value).flatMap { try? HubJSON.decode([String].self, from: $0) }
    }
}

// MARK: - Pairing and tokens

/// What a device needs to use the hub: `neoless://pair?server=<URL>&token=<token>&name=<name>`, printed by
/// `neoless-hub pair --name "iPhone"` and shown as a QR code. With Cloudflare Access in front of the hub (docs/hub.md,
/// "Access 双重锁") the link also carries the service token: `&cfid=<Client ID>&cfsecret=<Client Secret>`. Links
/// without them still work.
public struct HubPairing: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let scheme = "neoless"
    public static let host = "pair"
    /// Longest device name (`neoless-hub pair --name`); a link's longer name is cut.
    public static let maxNameLength = 40
    /// The link's query names of the Cloudflare Access service token.
    public static let accessIDItem = "cfid", accessSecretItem = "cfsecret"

    /// The hub's address, without a trailing slash: "https://hub.example.com".
    public var server: URL
    /// The device token (base64url).
    public var token: String
    /// The name this device was paired under ("iPhone").
    public var name: String
    /// The Cloudflare Access service token every request carries (双重锁), or nil when the hub has none.
    public var access: HubAccess?

    /// Checks and normalises the parts: the server must be https (http only for this Mac itself), the token
    /// base64url.
    public init(server: URL, token: String, name: String, access: HubAccess? = nil) throws {
        guard let normalized = Self.normalize(server) else { throw HubProtocolError.badServer }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HubToken.isWellFormed(token) else { throw HubProtocolError.badToken }
        self.server = normalized
        self.token = token
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.access = access
    }

    /// Reads a `neoless://pair?…` link (scanned, opened, or pasted with stray spaces around it).
    public init(link: String) throws {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else { throw HubProtocolError.notPairLink }
        try self.init(url: url)
    }

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme,
              (parts.host ?? parts.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == Self.host
        else { throw HubProtocolError.notPairLink }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let serverText = value("server"), let server = URL(string: serverText) else { throw HubProtocolError.badServer }
        guard let token = value("token") else { throw HubProtocolError.badToken }
        // Both or neither: half a service token gets no further than Cloudflare.
        let id = value(Self.accessIDItem).flatMap { $0.isEmpty ? nil : $0 }
        let secret = value(Self.accessSecretItem).flatMap { $0.isEmpty ? nil : $0 }
        var access: HubAccess?
        switch (id, secret) {
        case (nil, nil): access = nil
        case let (id?, secret?): access = try HubAccess(clientID: id, clientSecret: secret)
        default: throw HubProtocolError.badAccess
        }
        try self.init(server: server, token: token, name: Self.linkName(value("name") ?? ""), access: access)
    }

    /// A link's name as a device may show it: one line, no control characters, at most `maxNameLength`.
    static func linkName(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let line = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return String(line.prefix(maxNameLength))
    }

    /// The link, every value percent-encoded (so a name with "&", "+" or 中文 survives any scanner).
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = Self.host
        var items = [
            URLQueryItem(name: "server", value: HubQuery.encode(server.absoluteString)),
            URLQueryItem(name: "token", value: HubQuery.encode(token)),
        ]
        if let access {
            items.append(URLQueryItem(name: Self.accessIDItem, value: HubQuery.encode(access.clientID)))
            items.append(URLQueryItem(name: Self.accessSecretItem, value: HubQuery.encode(access.clientSecret)))
        }
        items.append(URLQueryItem(name: "name", value: HubQuery.encode(name)))
        parts.percentEncodedQueryItems = items
        return parts.url!
    }

    /// Never the token or the Access secret, in a log, an error or a debugger's dump: the server, the name and
    /// whether there are Access credentials (their masked Client ID).
    public var description: String {
        "HubPairing(\(server.absoluteString), name: \(name), access: \(access?.maskedID ?? "none"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["server": server.absoluteString, "name": name, "access": access?.maskedID ?? "none"],
               displayStyle: .struct)
    }

    /// https with a host, or http to this Mac itself; no query, fragment, user or trailing slash.
    static func normalize(_ server: URL) -> URL? {
        guard var parts = URLComponents(url: server, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil
        else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        parts.scheme = scheme
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }
}

/// A Cloudflare Access service token (Zero Trust › Access controls › Service credentials): its Client ID and Client Secret go
/// with every request as `CF-Access-Client-Id` / `CF-Access-Client-Secret`, so Cloudflare lets the request through
/// to the Neo; without them Cloudflare stops it (docs/hub.md, "Access 双重锁"). Kept with the device token (the
/// device's Keychain item, the hub's `cloudflare-access.json`), never in UserDefaults or a log.
public struct HubAccess: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                         CustomReflectable {
    /// "0123456789abcdef0123456789abcdef.access".
    public let clientID: String
    public let clientSecret: String

    /// Checks the parts: each 8 to 512 visible ASCII characters (they go into HTTP headers), not the same.
    public init(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isWellFormed(id), Self.isWellFormed(secret), id != secret else { throw HubProtocolError.badAccess }
        self.clientID = id
        self.clientSecret = secret
    }

    private enum CodingKeys: String, CodingKey { case clientID, clientSecret }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(clientID: c.decode(String.self, forKey: .clientID), clientSecret: c.decode(String.self, forKey: .clientSecret))
    }

    public static func isWellFormed(_ value: String) -> Bool {
        (8...512).contains(value.count) && value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    /// The headers every request carries.
    public var headers: [String: String] {
        [HubHeader.accessClientID: clientID, HubHeader.accessClientSecret: clientSecret]
    }

    /// The Client ID as it may be shown: "0123…cdef.access". The secret is never shown.
    public var maskedID: String {
        let suffix = ".access"
        let core = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        let tail = clientID.hasSuffix(suffix) ? suffix : ""
        guard core.count > 8 else { return "…" + tail }
        return String(core.prefix(4)) + "…" + String(core.suffix(4)) + tail
    }

    /// Cloudflare's Client IDs end in ".access"; a secret that does and an ID that does not were swapped.
    public var looksSwapped: Bool { clientSecret.hasSuffix(".access") && !clientID.hasSuffix(".access") }

    /// Never the secret, in a log, an error or a debugger's dump (`dump`, `Mirror` and `String(reflecting:)` too).
    public var description: String { "HubAccess(\(maskedID))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["clientID": maskedID], displayStyle: .struct) }
}

/// Device tokens: 32 random bytes as base64url. The hub keeps only their SHA-256.
public enum HubToken {
    public static func generate() -> String {
        Base64URL.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Lower-case hex SHA-256 of the token's UTF-8, as `devices.json` stores it.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `token` hashes to `hash`, in time that does not depend on where they differ.
    public static func matches(_ token: String, hash expected: String) -> Bool {
        let actual = Array(hash(token).utf8), wanted = Array(expected.lowercased().utf8)
        guard actual.count == wanted.count else { return false }
        return zip(actual, wanted).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// base64url, 16 to 512 characters.
    public static func isWellFormed(_ token: String) -> Bool {
        (16...512).contains(token.count) && token.unicodeScalars.allSatisfy(Base64URL.isAlphabet)
    }
}

/// Query values percent-encoded so that only unreserved characters stay as they are.
enum HubQuery {
    static let unreserved: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
