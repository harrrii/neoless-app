import Foundation
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// `POST /v1/learning/judge`: words the rules could not decide about are put to ChatGPT with what was heard, and
/// what it judges misheard is learned as `.judged`. Never a pair a rule forbids, never one the dictation does not
/// have. All text here is made up.
@MainActor
@Suite(.serialized) struct HubJudgeTests {
    private func pair(_ wrong: String, _ right: String) -> CorrectionPair { CorrectionPair(wrong: wrong, right: right) }

    @Test func misheardWordsAreLearnedAsJudged() async throws {
        let hub = try HubFixture()
        let dictation = try await hub.service.polish(PolishRequest(text: "帮我打开萝卜看看日志", mode: .natural,
                                                                 autoStructured: false, appName: "Claude"))
        hub.polisher.judgeAnswer = { asked in asked.filter { $0.right == "Notion" } }
        let answer = try decode(LearningJudgeResponse.self, try await hub.post(HubPath.learningJudge, LearningJudgeRequest(
            dictationID: dictation.id, pairs: [pair("萝卜", "Notion"), pair("日志", "记录")])))
        #expect(answer.learned == [pair("萝卜", "Notion")])
        #expect(answer.notMisheard == [pair("日志", "记录")])
        // ChatGPT was shown what was heard and what was delivered, and only the pairs a rule allows.
        let call = try #require(hub.polisher.judgeCalls.last)
        #expect(call.heard == dictation.raw && call.delivered == dictation.text && call.pairs.count == 2)
        // Learned like a correction, marked as judged, and listed with its kind.
        let item = try #require(hub.service.words.book.items.first { $0.pair == pair("萝卜", "Notion") })
        #expect(item.kind == .judged && item.count == 1 && item.recordIDs == [dictation.id])
        #expect(hub.service.learning.pairs.contains { $0.right == "Notion" && $0.kind == .judged })
        // Used in the next polish of a transcript that has the word, as a correction.
        _ = try await hub.service.polish(PolishRequest(text: "萝卜又报错了", mode: .natural, autoStructured: false, appName: "Claude"))
        #expect(hub.polisher.calls.last?.corrections.contains(pair("萝卜", "Notion")) == true)
        // Asked again about the same dictation: counted once.
        _ = try await hub.service.judge(LearningJudgeRequest(dictationID: dictation.id, pairs: [pair("萝卜", "Notion")]))
        #expect(hub.service.words.book.items.first { $0.pair.right == "Notion" }?.count == 1)
    }

    @Test func forbiddenOrUnknownPairsAreNeverAsked() async throws {
        let hub = try HubFixture()
        let dictation = try await hub.service.polish(PolishRequest(text: "周五和王伟去广州", mode: .natural,
                                                                 autoStructured: false, appName: "微信"))
        hub.polisher.judgeAnswer = { $0 }
        // A weekday, one person for another, one place for another, and a word the dictation does not have.
        let asked = [pair("周五", "周日"), pair("王伟", "王磊"), pair("广州", "杭州"), pair("米线", "曲线")]
        let answer = try await hub.service.judge(LearningJudgeRequest(dictationID: dictation.id, pairs: asked))
        #expect(answer.learned.isEmpty && Set(answer.notMisheard.map(\.right)) == Set(asked.map(\.right)))
        #expect(hub.polisher.judgeCalls.isEmpty)
        #expect(hub.service.words.book.items.isEmpty)
        // An unknown dictation.
        await #expect(throws: HubFailure.self) {
            try await hub.service.judge(LearningJudgeRequest(dictationID: UUID(), pairs: [pair("米线", "曲线")]))
        }
    }

    @Test func aFailedQuestionLearnsNothing() async throws {
        let hub = try HubFixture()
        let dictation = try await hub.service.polish(PolishRequest(text: "看一下米线的走势", mode: .natural,
                                                                 autoStructured: false, appName: "Claude"))
        hub.polisher.judgeAnswer = { _ in throw PolishError.timeout }
        await #expect(throws: HubFailure.self) {
            try await hub.service.judge(LearningJudgeRequest(dictationID: dictation.id, pairs: [pair("米线", "曲线")]))
        }
        #expect(hub.service.words.book.items.isEmpty)
    }
}
