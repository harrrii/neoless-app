import Foundation
import Testing
@testable import NeolessCloud
@testable import NeolessCore

private let token = "dGVzdC10b2tlbi0xMjM0NTY3ODkwYWJjZGVmZ2hpams"

private func respond<T: Encodable>(_ value: T, status: Int = 200) -> StubProtocol.Reply {
    .respond(status: status, headers: ["Content-Type": "application/json"], body: json(value))
}

private func pair(_ wrong: String, _ right: String) -> CorrectionPair { CorrectionPair(wrong: wrong, right: right) }

/// What a device learns from the hub's answer to its corrections: which ones the hub did not take, and which
/// ones may go again when the answer is lost. All text here is made up.
@Suite struct HubObservationTests {
    /// Room for a busy machine: every answer here comes at once, so a long wait for the connection costs nothing,
    /// and a short one would turn "the answer was lost" into "the hub was not reached" when the suites run together.
    private let roomy = HubTimeouts(connect: 5, quick: 10, ping: 5, hubPolishFloor: 1)

    private func client(_ host: String) -> HubClient {
        HubClient(server: URL(string: "https://\(host)")!, token: token, session: StubProtocol.session(), timeouts: roomy)
    }

    @Test func theNewFieldsAreLeftOutWhenEmpty() throws {
        // A device and a hub from before them read each other as they always did.
        let plain = LearningObservations(pairs: [pair("金币", "硬币")])
        #expect(try HubJSON.encode(plain) == Data(#"{"pairs":[{"right":"硬币","wrong":"金币"}]}"#.utf8))
        #expect(try HubJSON.decode(LearningObservations.self, from: Data(#"{"pairs":[]}"#.utf8)).id == nil)
        let old = try HubJSON.decode(LearningObservationsResponse.self, from: Data(#"{"accepted":1}"#.utf8))
        #expect(old == LearningObservationsResponse(accepted: 1) && old.refused == nil && old.id == nil)

        let id = UUID()
        let sent = LearningObservations(pairs: [pair("金币", "硬币")], dictationID: UUID(), id: id)
        #expect(try HubJSON.decode(LearningObservations.self, from: HubJSON.encode(sent)) == sent)
        let answer = LearningObservationsResponse(accepted: 0, refused: [pair("金币", "硬币")], terms: ["Nio"], id: id)
        #expect(try HubJSON.decode(LearningObservationsResponse.self, from: HubJSON.encode(answer)) == answer)
    }

    @Test func theOutboxKeepsAnObservationsID() {
        var box = HubOutbox()
        let id = UUID(), dictation = UUID()
        box.observe([pair("金币", "硬币")], dictationID: dictation, id: id)
        box.observe([pair("Martn", "Martin")])
        #expect(box.observations == [LearningObservations(pairs: [pair("金币", "硬币")], dictationID: dictation, id: id),
                                     LearningObservations(pairs: [pair("Martn", "Martin")])])
    }

    @Test func aFlushSaysWhatTheHubDidNotTake() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, body, _ in
            let sent = (try? HubJSON.decode(LearningObservations.self, from: body))?.pairs ?? []
            // A hub that names what it refuses: everything but 金币 → 硬币.
            let refused = sent.filter { $0.wrong != "金币" }
            return respond(LearningObservationsResponse(accepted: sent.count - refused.count, refused: refused))
        }
        var box = HubOutbox()
        box.observe([pair("金币", "硬币"), pair("科德克斯", "Codex")])
        box.observe([pair("Martn", "Martin")])
        let result = await client(host).flush(box)
        #expect(result.left.isEmpty && result.stoppedBy == nil)
        #expect(result.refused == [pair("科德克斯", "Codex"), pair("Martn", "Martin")])
    }

    @Test func aHubThatNamesNothingRefusedWhatItTookNoneOf() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        // A hub from before it named them: only the count.
        StubProtocol.register(host: host) { _, body, _ in
            let sent = (try? HubJSON.decode(LearningObservations.self, from: body))?.pairs ?? []
            return respond(LearningObservationsResponse(accepted: sent.first?.wrong == "科德克斯" ? 0 : 1))
        }
        var box = HubOutbox()
        box.observe([pair("科德克斯", "Codex")])
        box.observe([pair("金币", "硬币"), pair("Martn", "Martin")])
        let result = await client(host).flush(box)
        // Zero of one: that one. One of two: which one is not known, so neither is called refused.
        #expect(result.refused == [pair("科德克斯", "Codex")])
        #expect(result.left.isEmpty)
    }

    @Test func aLostAnswerIsAskedForAgainOnlyWhenThatCannotCountTwice() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, _, _ in .fail(.networkConnectionLost) }

        // With an id and the record it comes from: the hub counts a pair once per record and keeps the records
        // on disk, whatever its version and also across a restart. It stays, marked as possibly arrived.
        var withRecord = HubOutbox()
        let id = UUID()
        withRecord.observe([pair("金币", "硬币")], dictationID: UUID(), id: id)
        let kept = await client(host).flush(withRecord)
        #expect(kept.left.observations == withRecord.observations && kept.left.unanswered == [id])
        #expect(kept.stoppedBy as? HubError == .connectionLost)

        // With an id alone: a hub's memory of ids may not outlive a restart, and it would then count the pair
        // twice. Dropped: better not learned there than counted twice.
        var alone = HubOutbox()
        alone.observe([pair("金币", "硬币")], id: UUID())
        let dropped = await client(host).flush(alone)
        #expect(dropped.left.observations.isEmpty && dropped.left.unanswered.isEmpty)
        #expect(dropped.stoppedBy as? HubError == .connectionLost)

        // Without an id it cannot be told apart on the hub: dropped, as before.
        var old = HubOutbox()
        old.observe([pair("金币", "硬币")], dictationID: UUID())
        #expect(await client(host).flush(old).left.observations.isEmpty)
    }

    @Test func anObservationSentAgainIsNoLongerUnansweredOnceAnswered() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, body, n in
            // The first request loses its answer; the ones after it are answered.
            guard n > 0 else { return .fail(.networkConnectionLost) }
            let sent = try? HubJSON.decode(LearningObservations.self, from: body)
            return respond(LearningObservationsResponse(accepted: 1, refused: [], id: sent?.id))
        }
        var box = HubOutbox()
        let id = UUID()
        box.observe([pair("金币", "硬币")], dictationID: UUID(), id: id)
        box.observe([pair("Martn", "Martin")], dictationID: UUID(), id: UUID())
        let first = await client(host).flush(box)
        // What follows waits, as the connection is shaky.
        #expect(first.left.unanswered == [id] && first.left.observations.count == 2)
        let second = await client(host).flush(first.left)
        #expect(second.left.isEmpty && second.left.unanswered.isEmpty && second.stoppedBy == nil)
        #expect(second.refused.isEmpty)
    }

    @Test func takingBackWhatMayHaveArrivedSendsTheReverseAfterIt() throws {
        let fix = pair("Open Air", "OpenAI"), id = UUID(), dictation = UUID()
        var box = HubOutbox()
        box.observe([fix], dictationID: dictation, id: id)
        // Never sent: taken back, and nothing goes.
        var fresh = box
        fresh.unlearn(fix, dictationID: dictation, hubHas: false)
        #expect(fresh.observations.isEmpty)

        // Sent, and the answer was lost: the hub may have counted it. Taking it out of the line would leave it
        // there. It stays, and the reverse follows it: sent again it is counted once for its record, then the
        // reverse counts it down, whether the first sending arrived or not.
        box.unanswered = [id]
        #expect(box.mayHaveReached(pair("open  air", "openai")))
        #expect(!box.mayHaveReached(pair("金币", "硬币")))
        box.unlearn(fix, dictationID: dictation, hubHas: false)
        #expect(box.observations == [LearningObservations(pairs: [fix], dictationID: dictation, id: id),
                                     LearningObservations(pairs: [pair("OpenAI", "Open Air")], dictationID: dictation)])
        #expect(box.unanswered == [id])

        // Saved with the mark; a file from before the mark reads as it always did.
        #expect(try JSONDecoder().decode(HubOutbox.self, from: JSONEncoder().encode(box)) == box)
        let before = try JSONDecoder().decode(HubOutbox.self, from: Data(#"{"forgotten":["x"],"observations":[],"edits":[]}"#.utf8))
        #expect(before.forgotten == ["x"] && before.unanswered.isEmpty)
        #expect(try !String(decoding: JSONEncoder().encode(HubOutbox()), as: UTF8.self).contains("unanswered"))

        // What a flush could not send comes back in front of what was added since, marks included.
        var since = HubOutbox()
        since.observe([pair("金币", "硬币")], dictationID: UUID(), id: UUID())
        since.merge(earlier: box)
        #expect(since.observations.count == 3 && since.unanswered == [id])

        // The correction is forgotten: the forgetting goes first and takes it off the hub if it arrived, so
        // neither the waiting observation nor the count-down that followed it is sent (alone on the hub, the
        // count-down would be judged as a correction of its own).
        box.forget("Open Air")
        #expect(box.forgotten == ["Open Air"] && box.observations.isEmpty && box.unanswered.isEmpty)
    }

    @Test func whatTheHubLacksIsReadOffItsList() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func item(_ wrong: String, _ right: String, seen: TimeInterval, record: UUID? = nil) -> LearnedCorrection {
            LearnedCorrection(pair: pair(wrong, right), firstSeen: now, lastSeen: now.addingTimeInterval(seen),
                              source: .otherApp, addedTerm: true, recordIDs: record.map { [$0] } ?? [])
        }
        let record = UUID()
        let book = LearningBook(items: [item("Open Air", "OpenAI", seen: 40), item("科德克斯", "Codex", seen: 30, record: record),
                                        item("斯威夫特", "Swift", seen: 20), item("金币", "硬币", seen: 10)])
        // The hub has the first (however it is written), the last is waiting to go.
        let hub = [LearningEntry(wrong: "open  air", right: "openai", count: 2, lastSeen: now)]
        let missing = HubLearning.missing(from: hub, hubWords: ["swift", "Claude"], book: book,
                                          pending: [LearningBook.key(pair("金币", "硬币"))])
        // Of the other two it holds nothing, or only the word (it judged the misheard side everyday text).
        #expect(missing == [LearningBook.key(pair("科德克斯", "Codex")): .nothing,
                            LearningBook.key(pair("斯威夫特", "Swift")): .wordOnly])
        #expect(HubLearning.missing(from: [], hubWords: [], book: book, pending: []).count == 4)
        #expect(HubLearning.missing(from: hub, hubWords: [], book: LearningBook(), pending: []).isEmpty)

        // Offered once more after the hub was updated: the latest first, one to an observation, each with the
        // record its fix came from (counted once for it) and an id of its own.
        let again = HubLearning.resend(book, missing: Set(missing.keys))
        #expect(again.map(\.pairs) == [[pair("科德克斯", "Codex")], [pair("斯威夫特", "Swift")]])
        #expect(again[0].dictationID == record && again[0].id != nil && again[1].dictationID == nil)
        let all = Set(book.items.map { LearningBook.key($0.pair) })
        #expect(HubLearning.resend(book, missing: all, limit: 1).map(\.pairs) == [[pair("Open Air", "OpenAI")]])
        #expect(HubLearning.resend(book, missing: []).isEmpty)
        // Half of what the hub takes as new in a day: the day's fresh fixes still find room.
        #expect(HubLearning.resendLimit == LearningBook.maxNewPerDay / 2)
    }
}
