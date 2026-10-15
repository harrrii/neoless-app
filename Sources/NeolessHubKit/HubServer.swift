import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NeolessCloud
import NeolessCore

/// Per-request state the middlewares share: which device is asking (for the routes and the log line).
public final class RequestNote: @unchecked Sendable {
    private let lock = NSLock()
    private var _device: HubDevice?

    public init() {}

    public var device: HubDevice? {
        get { lock.withLock { _device } }
        set { lock.withLock { _device = newValue } }
    }
}

public struct HubRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let note: RequestNote

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        note = RequestNote()
    }

    /// Set by `AuthMiddleware` on every route but `/v1/ping`.
    var device: HubDevice {
        get throws {
            guard let device = note.device else { throw HubFailure.unauthorized }
            return device
        }
    }
}

/// The hub's HTTP side (docs/hub.md, "HTTP 接口"): routes, Bearer auth, size and rate limits, Chinese error
/// bodies, one log line per request. 127.0.0.1 only; nothing a proxy adds is trusted.
public enum HubServer {
    public static let requestHeader = HTTPField.Name(HubHeader.request)!
    /// What Cloudflare Access adds to a request it let through (`HubConfig.requireAccess`).
    public static let accessJWTHeader = HTTPField.Name(HubHeader.accessJWT)!

    public static func router(service: HubService) -> Router<HubRequestContext> {
        let router = Router(context: HubRequestContext.self)
        router.add(middleware: LogMiddleware())
        router.add(middleware: AuthMiddleware(service: service))

        router.get(RouterPath(HubPath.ping)) { _, _ in try json(HubOK()) }

        router.get(RouterPath(HubPath.health)) { _, context in
            let device = try context.device
            return try json(await service.health(device: device))
        }

        router.post(RouterPath(HubPath.dictations)) { request, _ in
            try tooLarge(request, limit: Hub.maxAudioBytes, failure: .audioTooLarge)
            guard let type = request.headers[.contentType].flatMap(HubAudioType.init(contentType:)) else {
                throw HubFailure.unsupportedMedia
            }
            guard let header = request.headers[requestHeader], let dictation = try? DictationRequest(headerValue: header) else {
                throw HubFailure.badRequest(HubProtocolError.badRequestHeader.errorDescription ?? "听写请求的格式不对")
            }
            let audio = try await collect(request, limit: Hub.maxAudioBytes, failure: .audioTooLarge)
            return try json(await service.dictate(audio: audio, type: type, request: dictation))
        }

        router.post(RouterPath(HubPath.polish)) { request, _ in
            let body = try await decode(PolishRequest.self, from: request)
            return try json(await service.polish(body))
        }

        router.post("/v1/dictations/:id/repolish") { request, context in
            let id = try dictationID(context)
            let body = try await decode(RepolishRequest.self, from: request, emptyAs: RepolishRequest())
            return try json(await service.repolish(id: id, mode: body.mode))
        }

        router.post("/v1/dictations/:id/edit") { request, context in
            let id = try dictationID(context)
            let body = try await decode(EditRequest.self, from: request)
            return try json(await service.edit(id: id, text: body.text, learn: body.learn ?? true))
        }

        router.post(RouterPath(HubPath.learningObservations)) { request, _ in
            let body = try await decode(LearningObservations.self, from: request)
            return try json(await service.observe(body))
        }

        router.get(RouterPath(HubPath.learning)) { _, _ in try json(await service.learning) }

        router.post(RouterPath(HubPath.learningForget)) { request, _ in
            let body = try await decode(LearningForget.self, from: request)
            return try json(await service.forgetLearning(body))
        }

        router.delete(RouterPath(HubPath.learning)) { request, _ in
            guard let wrong = request.uri.queryParameters.get("wrong"), !wrong.isEmpty else {
                throw HubFailure.badRequest("缺少要删除的词")
            }
            return try json(await service.forgetLearning(wrong: wrong))
        }

        router.get(RouterPath(HubPath.vocabulary)) { _, _ in try json(await service.vocabulary) }

        router.put(RouterPath(HubPath.vocabulary)) { request, _ in
            // A whole dictionary at its limits is more than other JSON bodies may be.
            let body = try await decode(VocabularyUpdate.self, from: request, limit: Hub.maxVocabularyJSONBytes,
                                        failure: .vocabularyTooLarge)
            return try json(await service.updateVocabulary(body))
        }

        router.get(RouterPath(HubPath.habits)) { _, _ in try json(await service.habits) }

        router.put(RouterPath(HubPath.habits)) { request, _ in
            // A dozen short lines: far less than other JSON bodies may be.
            let body = try await decode(HabitsUpdate.self, from: request, limit: WordStore.maxHabitsJSONBytes,
                                        failure: .habitsTooLarge)
            return try json(await service.updateHabits(body))
        }

        router.get(RouterPath(HubPath.history)) { request, _ in
            let query = request.uri.queryParameters
            var limit = Hub.defaultHistoryLimit
            if let text = query.get("limit") {
                guard let value = Int(text), value > 0 else { throw HubFailure.badRequest("limit 不对") }
                limit = value
            }
            var before: Date?
            if let text = query.get("before") {
                guard let date = HubJSON.date(from: text) else { throw HubFailure.badRequest("before 不对") }
                before = date
            }
            return try json(await service.historyPage(limit: limit, before: before))
        }

        router.delete("/v1/history/:id") { _, context in
            try await service.deleteHistory(id: try dictationID(context))
            return try json(HubOK())
        }

        router.get(RouterPath(HubPath.sync)) { _, _ in try json(await service.sync) }

        router.post(RouterPath(HubPath.warm)) { request, context in
            let device = try context.device
            let body = try await decode(WarmRequest.self, from: request, emptyAs: WarmRequest())
            await service.warm(device: device, request: body)
            return try json(HubOK())
        }

        return router
    }

    /// The hub on 127.0.0.1:`port`.
    public static func application(service: HubService, port: Int = Hub.port,
                                   onRunning: @escaping @Sendable () async -> Void = {}) -> some ApplicationProtocol {
        var logger = Logger(label: "neoless-hub")
        logger.logLevel = .warning
        return Application(router: router(service: service),
                           configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: port)),
                           onServerRunning: { _ in await onRunning() },
                           logger: logger)
    }

    // MARK: - Bodies

    /// 413 at once when the declared length is over the limit.
    static func tooLarge(_ request: Request, limit: Int, failure: HubFailure) throws {
        if let length = request.headers[.contentLength].flatMap({ Int($0) }), length > limit { throw failure }
    }

    /// The body, read as it streams in and refused (413) as soon as it passes `limit`.
    static func collect(_ request: Request, limit: Int, failure: HubFailure) async throws -> Data {
        try tooLarge(request, limit: limit, failure: failure)
        var data = Data()
        for try await buffer in request.body {
            guard data.count + buffer.readableBytes <= limit else { throw failure }
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }

    /// A JSON body (at most 256 KB unless `limit` says otherwise). Malformed → 400.
    static func decode<T: Decodable>(_ type: T.Type, from request: Request, emptyAs empty: T? = nil,
                                     limit: Int = Hub.maxJSONBytes, failure: HubFailure = .jsonTooLarge) async throws -> T {
        let data = try await collect(request, limit: limit, failure: failure)
        if data.isEmpty, let empty { return empty }
        guard let value = try? HubJSON.decode(T.self, from: data) else { throw HubFailure.badRequest() }
        return value
    }

    static func dictationID(_ context: HubRequestContext) throws -> UUID {
        guard let id = context.parameters.get("id", as: UUID.self) else { throw HubFailure.badRequest("记录编号不对") }
        return id
    }

    // MARK: - Responses

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try HubJSON.encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// Any error as the contract's `{"error", "code", "retryable"}` answer.
    static func failure(for error: Error) -> HubFailure {
        switch error {
        case let failure as HubFailure:
            return failure
        case let error as HTTPError:
            // Each `code` goes with one status (docs/hub.md): the server's own trouble is `internal` (retryable),
            // a route that does not take this method is no route, any other refusal of the request is 400.
            switch error.status.code {
            case 404, 405: return .noRoute
            case 413: return .jsonTooLarge
            case 500...: return .internalError
            default: return .badRequest()
            }
        default:
            HubLog.write("error: \(String(describing: type(of: error)))")
            return .internalError
        }
    }

    static func response(for failure: HubFailure) -> Response {
        let status = HTTPResponse.Status(code: failure.status)
        return (try? json(failure.body, status: status)) ?? Response(status: status)
    }
}

/// Outermost: turns every error into the contract's answer and logs one line per request of a paired device
/// (method, route, status, time, device). Requests without a device (no or a wrong token, `/v1/ping`) are only
/// counted, one line a minute (`QuietRequests`): anyone on the internet can send them, and the log is a file on
/// the Neo's disk. Never bodies, transcripts or tokens.
struct LogMiddleware: RouterMiddleware {
    typealias Context = HubRequestContext

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let start = ContinuousClock.now
        let response: Response
        do {
            response = try await next(request, context)
        } catch {
            response = HubServer.response(for: HubServer.failure(for: error))
        }
        if let device = context.note.device?.name {
            let route = context.endpointPath.flatMap { $0 == "NotFound" ? nil : $0 } ?? String(request.uri.path.prefix(80))
            HubLog.request(method: request.method.rawValue, route: route, status: response.status.code,
                           ms: HubService.ms(since: start), device: device)
        } else {
            QuietRequests.shared.count(ping: context.endpointPath == HubPath.ping, status: response.status.code)
        }
        return response
    }
}

/// Requests without a paired device, counted and logged as one line a minute: "没有设备的请求：ping 12，401 3".
final class QuietRequests: @unchecked Sendable {
    static let shared = QuietRequests()
    static let window: TimeInterval = 60

    private let lock = NSLock()
    private var since: Date?
    private var counts: [String: Int] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func count(ping: Bool, status: Int) {
        let line: String? = lock.withLock {
            let time = now()
            var summary: String?
            if let since, time.timeIntervalSince(since) >= Self.window {
                summary = Self.summary(counts)
                counts = [:]
                self.since = nil
            }
            if self.since == nil { self.since = time }
            counts[ping ? "ping" : String(status), default: 0] += 1
            return summary
        }
        if let line { HubLog.write(line) }
    }

    /// Writes what was counted so far (for `serve` as it stops).
    func flush() {
        let line: String? = lock.withLock {
            defer { counts = [:]; since = nil }
            return counts.isEmpty ? nil : Self.summary(counts)
        }
        if let line { HubLog.write(line) }
    }

    static func summary(_ counts: [String: Int]) -> String {
        "没有设备的请求：" + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，")
    }
}

/// Every route but `/v1/ping` needs a paired device's token, and counts against its 30 requests a minute (one
/// limit for the dictation calls, one for warm-ups, one for the rest: `HubService.RequestKind`). With `requireAccess` it must also have
/// come through Cloudflare Access (checked first, so nothing about the token is said to what did not).
struct AuthMiddleware: RouterMiddleware {
    typealias Context = HubRequestContext
    let service: HubService

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        if context.endpointPath == HubPath.ping { return try await next(request, context) }
        try await service.checkAccess(jwt: request.headers[HubServer.accessJWTHeader])
        let authorization = request.headers[.authorization]
        let device = try await service.identify(authorization)
        // Known from here on, so the log line of a 429 says whose it was.
        context.note.device = device
        try await service.admit(device, kind: HubService.RequestKind.of(route: context.endpointPath ?? request.uri.path))
        return try await next(request, context)
    }
}
