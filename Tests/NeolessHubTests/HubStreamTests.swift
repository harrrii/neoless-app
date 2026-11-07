import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// 边说边传: a long recording with 大模型 arrives piece by piece while the user speaks; `…/finish` joins the pieces'
/// text and polishes it as one dictation.
@MainActor
@Suite struct HubStreamTests {
    @Test func piecesAreRecognisedAsTheyArriveAndFinishedAsOneDictation() async throws {
        let hub = try HubFixture()
        hub.asr.replies = [.text("第一段讲通胀。"), .text("第二段讲 Fisher"), .text("effect 和名义利率。")]
        let request = dictation(local: nil).asking(for: .large)
        for index in 0..<3 {
            let answer = try decode(StreamChunkAnswer.self, try await hub.chunk(request, index))
            #expect(answer.index == index && answer.seconds > 0.9)
        }
        // Recognised before the user stops: nothing is left for the finish but joining and polishing.
        #expect(await eventually { hub.asr.calls.count == 3 })
        let result = try decode(DictationResult.self, try await hub.finish(request, chunks: 3))
        #expect(result.raw == "第一段讲通胀。第二段讲 Fisher effect 和名义利率。")
        #expect(result.recognizer == .qwen3ASR && result.clientRecordingID == request.clientRecordingID)
        #expect(hub.asr.calls.allSatisfy { $0.model == .large })
        #expect(hub.polisher.calls.map(\.transcript) == [result.raw])
        #expect(hub.service.history.entries.count == 1)
        #expect(hub.service.openStreams == 0)
        // Asked again (a device that ran out of time): the same result, nothing recognised or polished again.
        let again = try decode(DictationResult.self, try await hub.finish(request, chunks: 3))
        #expect(again.id == result.id && hub.asr.calls.count == 3 && hub.polisher.calls.count == 1)
    }

    @Test func aPieceSentTwiceIsRecognisedOnce() async throws {
        let hub = try HubFixture()
        let request = dictation().asking(for: .large)
        _ = try await hub.chunk(request, 0)
        _ = try await hub.chunk(request, 0)
        #expect(await eventually { hub.asr.calls.count == 1 })
        _ = try decode(DictationResult.self, try await hub.finish(request, chunks: 1))
        #expect(hub.asr.calls.count == 1)
    }

    @Test func missingPiecesAreNamedAndTheFinishWorksOnceTheyCome() async throws {
        let hub = try HubFixture()
        hub.asr.replies = [.text("一"), .text("三"), .text("二")]
        let request = dictation().asking(for: .large)
        _ = try await hub.chunk(request, 0)
        _ = try await hub.chunk(request, 2)
        let refused = try await hub.finish(request, chunks: 3)
        #expect(refused.status == .conflict)
        let body = try #require(errorBody(refused))
        #expect(body.code == HubErrorCode.missingChunks && body.missing == [1] && body.retryable)
        _ = try await hub.chunk(request, 1)
        let result = try decode(DictationResult.self, try await hub.finish(request, chunks: 3))
        // In the pieces' order, whatever order they were recognised in.
        #expect(result.raw == "一二三")
    }

    @Test func aHubThatLostEverythingAsksForEveryPiece() async throws {
        let hub = try HubFixture()
        let request = dictation().asking(for: .large)
        let refused = try await hub.finish(request, chunks: 2)
        #expect(errorBody(refused)?.missing == [0, 1])
    }

    @Test func aPieceWhoseRecognitionFailedIsTriedAgainAtTheFinish() async throws {
        let hub = try HubFixture()
        hub.asr.replies = [.fail(.unreachable), .text("第二次听到了")]
        let request = dictation().asking(for: .large)
        _ = try await hub.chunk(request, 0)
        #expect(await eventually { hub.asr.calls.count == 1 })
        let result = try decode(DictationResult.self, try await hub.finish(request, chunks: 1))
        #expect(result.raw == "第二次听到了" && hub.asr.calls.count == 2)
    }

    @Test func aWorkerThatStaysDownIsSaidAsSuchAndTheTranscriptCanFollow() async throws {
        let hub = try HubFixture()
        hub.asr.reply = .fail(.unreachable)
        let request = dictation(local: "本机听到的话").asking(for: .large)
        _ = try await hub.chunk(request, 0)
        let refused = try await hub.finish(request, chunks: 1)
        #expect(refused.status == .serviceUnavailable && errorBody(refused)?.code == HubErrorCode.asrUnavailable)
        #expect(HubDictation.transcriptFollows(HubError.server(status: 503, body: errorBody(refused)), request: request))
        let polished = try decode(DictationResult.self, try await hub.post(HubPath.polish, request.polishRequest(text: "本机听到的话")))
        #expect(polished.recognizer == .local)
    }

    @Test func aDroppedRecordingIsForgotten() async throws {
        let hub = try HubFixture()
        let request = dictation().asking(for: .large)
        _ = try await hub.chunk(request, 0)
        #expect(hub.service.openStreams == 1)
        let dropped = try await hub.send(.delete, HubPath.stream(request.clientRecordingID))
        #expect(dropped.status == .ok)
        #expect(hub.service.openStreams == 0)
    }

    @Test func aPieceForAnotherRecordingThanThePathIsRefused() async throws {
        let hub = try HubFixture()
        let request = dictation().asking(for: .large)
        let wrong = try await hub.send(.put, HubPath.streamChunk(UUID(), index: 0), headers: try hub.dictationHeaders(request),
                                       body: ByteBuffer(bytes: AudioFixture.m4a))
        #expect(wrong.status == .badRequest)
        let outOfRange = try await hub.chunk(request, Hub.maxStreamChunks)
        #expect(outOfRange.status == .badRequest)
    }

    @Test func piecesCountAsDictations() {
        #expect(HubService.RequestKind.of(route: "/v1/streams/:id/chunks/:index") == .dictation)
        #expect(HubService.RequestKind.of(route: "/v1/streams/:id/finish") == .dictation)
    }
}
