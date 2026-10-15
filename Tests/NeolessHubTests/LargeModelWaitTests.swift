import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// 识别模型 › 大模型 on the device says "一直用大模型，Neo 忙时要多等一会儿". What makes that so is on both sides:
/// the device's request for the large model carries no transcript of its own (`DictationRequest.asking`), and a
/// hub without one waits for its worker instead of giving up on a busy Neo after `ASRWorker.impatientTimeout`.
@MainActor
@Suite struct LargeModelWaitTests {
    @Test func aRecordingAskingForTheLargeModelIsWaitedFor() async throws {
        let hub = try HubFixture()
        let gate = Gate()
        hub.asr.gate = gate            // a busy worker: no answer yet
        hub.asr.reply = .text("大模型听到的话")
        hub.service.impatientTimeout = { _ in 0.2 }
        // Well past the impatient wait, the worker answers: counted from when it was asked, since decoding the
        // audio first can take long on a busy Mac (as in HubRouteTests).
        Task {
            _ = await eventually { gate.arrived == 1 }
            try? await Task.sleep(nanoseconds: 600_000_000)
            gate.open()
        }
        let request = dictation(local: "本机听到的话").asking(for: .large)
        let result = try decode(DictationResult.self, try await hub.dictate(request))
        #expect(result.recognizer == .qwen3ASR && result.raw == "大模型听到的话")
        // And it is the large model the worker was asked for (`X-Model`).
        #expect(hub.asr.calls.map(\.model) == [.large])
    }

    @Test func theSameRecordingWithItsTranscriptIsNot() async throws {
        // What 自动 and 小模型 send: the transcript comes along, and a busy Neo costs accuracy, not time.
        let hub = try HubFixture()
        let gate = Gate()
        hub.asr.gate = gate
        hub.service.impatientTimeout = { _ in 0.2 }
        // Let go only after the impatient wait ran out, counted from when the worker was asked: let go any
        // sooner (the audio still decoding on a busy Mac), the worker would answer in time and be used.
        Task {
            _ = await eventually { gate.arrived == 1 }
            try? await Task.sleep(nanoseconds: 600_000_000)
            gate.open()
        }
        let request = dictation(local: "本机听到的话").asking(for: .small)
        let result = try decode(DictationResult.self, try await hub.dictate(request))
        #expect(result.recognizer == .local && result.raw == "本机听到的话")
        #expect(hub.asr.calls.map(\.model) == [.small])
    }

    @Test func theChoiceInSettingsIsTheModelTheWorkerIsAskedFor() async throws {
        // The device's half (`DictationRequest.asking`, what 识别模型 sends) and the hub's (`X-Model` to its
        // worker) were written apart: 自动 says nothing and is `auto`, the other two arrive as chosen.
        let hub = try HubFixture()
        for (chosen, asked): (HubASRModel?, HubASRModel) in [(nil, .auto), (.auto, .auto), (.large, .large), (.small, .small)] {
            let request = dictation(local: "本机听到的话").asking(for: chosen)
            _ = try decode(DictationResult.self, try await hub.dictate(request))
            #expect(hub.asr.calls.last?.model == asked, "\(String(describing: chosen))")
        }
        #expect(hub.asr.calls.count == 4)
    }

    @Test func aNeoThatCannotListenIsToldSoAndTakesTheTranscriptAfterwards() async throws {
        // The worker is down. Without a transcript the hub can only say so; the device then sends its own to
        // /v1/polish under the same recording id (`HubDictation.transcriptFollows`), and nothing is in the way.
        let hub = try HubFixture()
        hub.asr.reply = .fail(.unreachable)
        let request = dictation(local: "本机听到的话").asking(for: .large)
        let refused = try await hub.dictate(request)
        #expect(refused.status == .serviceUnavailable)
        let body = try #require(errorBody(refused))
        #expect(body.code == HubErrorCode.asrUnavailable)
        #expect(HubDictation.transcriptFollows(HubError.server(status: 503, body: body), request: request))
        let polished = try decode(DictationResult.self, try await hub.post(HubPath.polish, request.polishRequest(text: "本机听到的话")))
        #expect(polished.recognizer == .local && polished.raw == "本机听到的话")
        #expect(polished.clientRecordingID == request.clientRecordingID)
        #expect(hub.service.history.entries.count == 1)
    }

    @Test func theDeviceWaitsAtLeastAsLongAsTheHubDoes() {
        // The device's budget for a request that waits is built from the hub's own wait for its worker
        // (`ASRWorker.timeout`): the hub's answer, an error included, comes before the device gives up.
        #expect(ASRWorker.timeout(audioSeconds: 0) == HubTimeouts.patientModelLoad)
        #expect(ASRWorker.timeout(audioSeconds: 40) == HubTimeouts.patientModelLoad + 40 * HubTimeouts.patientASRPerAudioSecond)
        for seconds: Double in [0, 5, 20, 60, 120, 420, 600] {
            #expect(HubTimeouts.standard.dictation(durationSeconds: seconds, audioBytes: 0, patient: true)
                    >= ASRWorker.timeout(audioSeconds: seconds))
        }
        // Where someone waits, no call is given more than 90 s: a recording up to about a minute and a half is
        // still covered in full.
        #expect(HubTimeouts.interactive.dictation(durationSeconds: 60, audioBytes: 240_000, patient: true)
                >= ASRWorker.timeout(audioSeconds: 60))
    }
}
