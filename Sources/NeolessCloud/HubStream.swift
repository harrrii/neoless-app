import Foundation
import NeolessCore

// 边说边传 (docs/hub.md): with 识别模型 › 大模型, a long recording goes to the Neo piece by piece while the user
// speaks, cut in pauses (`StreamCut`). The Neo recognises each piece as it arrives; once the user stops only the
// last piece is left, and `…/finish` joins the pieces' text and polishes it as one dictation. The large model on a
// busy Neo takes about a fifth of the recording's length: 91 s for 7.8 minutes, nearly all of it now while the
// user is still speaking.

/// `PUT /v1/streams/{id}/chunks/{index}`: the piece arrived and was decoded; it is recognised in the background.
public struct StreamChunkAnswer: Codable, Equatable, Sendable {
    public var index: Int
    public var seconds: Double

    public init(index: Int, seconds: Double) { self.index = index; self.seconds = seconds }
}

/// `POST /v1/streams/{id}/finish`: how many pieces the recording has (0…`chunks` − 1).
public struct StreamFinishRequest: Codable, Equatable, Sendable {
    public var chunks: Int

    public init(chunks: Int) { self.chunks = chunks }
}

extension Hub {
    /// The most pieces one recording may have: ten minutes cut at `StreamCut.minSeconds`, and room to spare.
    public static let maxStreamChunks = 60
}

/// Sends the pieces of one recording to the hub (`HubClient.streamChunk`) and then finishes it. Pieces may be sent
/// in any order and again (the hub keeps one of each); a piece that did not get through is sent again when the
/// hub says at `…/finish` that it lacks it (409 `missing_chunks`).
public actor HubStreamSender {
    public enum Failure: Error, Equatable, Sendable {
        /// The hub does not know `/v1/streams` (one from before it): the recording goes whole.
        case unsupported
        /// The hub kept saying it lacks pieces this device has sent again.
        case incomplete
    }

    public typealias SendChunk = @Sendable (EncodedAudio, Int) async throws -> Void
    public typealias Drop = @Sendable () async -> Void

    private let sendChunk: SendChunk
    private let drop: Drop
    private let encode: @Sendable ([Float]) -> EncodedAudio
    private var pieces: [Int: EncodedAudio] = [:]
    private var unsupported = false
    private var dropped = false

    /// How many times a piece is tried while the user speaks; a piece that still did not get through is sent at
    /// `…/finish`.
    static let tries = 3
    /// Rounds of sending what the hub lacks before the recording is given up on as pieces.
    static let finishRounds = 3

    public init(encode: @escaping @Sendable ([Float]) -> EncodedAudio = { AudioUpload.encode($0) },
                send: @escaping SendChunk, drop: @escaping Drop = {}) {
        self.encode = encode
        sendChunk = send
        self.drop = drop
    }

    /// Whether the hub turned the pieces away as unknown (`Failure.unsupported`).
    public var isUnsupported: Bool { unsupported }

    /// Encodes piece `index` and sends it, trying again a few times when the network or the Neo is in the way.
    public func add(_ samples: [Float], index: Int) async {
        let audio = encode(samples)
        pieces[index] = audio
        for attempt in 0..<Self.tries {
            guard !unsupported, !dropped else { return }
            do {
                try await sendChunk(audio, index)
                return
            } catch {
                if Self.isUnknownRoute(error) { unsupported = true; return }
                if error is CancellationError || !Self.isTransient(error) { return }
                if attempt + 1 < Self.tries { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
            }
        }
    }

    /// Finishes the recording of `chunks` pieces with `finish`, sending again the pieces the hub says it lacks.
    /// Throws `Failure.unsupported` for a hub from before `/v1/streams`, and `finish`'s own errors (a timeout: the
    /// hub is still recognising; ask again).
    public func finish(chunks: Int, _ finish: @Sendable (Int) async throws -> DictationResult) async throws -> DictationResult {
        guard !unsupported else { throw Failure.unsupported }
        for _ in 0..<Self.finishRounds {
            do {
                return try await finish(chunks)
            } catch let HubError.server(409, body?) where body.code == HubErrorCode.missingChunks {
                for index in body.missing ?? [] {
                    guard let audio = pieces[index] else { throw Failure.incomplete }
                    try await sendChunk(audio, index)
                }
            } catch {
                if Self.isUnknownRoute(error) { unsupported = true; throw Failure.unsupported }
                throw error
            }
        }
        throw Failure.incomplete
    }

    /// The recording is not finished as pieces (cancelled, or sent whole): the hub forgets the pieces it has.
    public func cancel() async {
        guard !dropped else { return }
        dropped = true
        guard !pieces.isEmpty, !unsupported else { return }
        await drop()
    }

    /// A hub from before `/v1/streams`: its 404 (no route), or a 405.
    static func isUnknownRoute(_ error: Error) -> Bool {
        guard case .server(let status, _)? = error as? HubError else { return false }
        return status == 404 || status == 405
    }

    /// Worth sending again in a moment: the network, Cloudflare, a busy or restarting Neo.
    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? HubError else { return false }
        switch error {
        case .offline, .unreachable, .connectionLost, .timeout: return true
        case .server(let status, let body): return status == 429 || status >= 500 || body?.retryable == true
        default: return false
        }
    }
}
