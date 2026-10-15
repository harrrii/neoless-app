import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// What the hub makes of corrections a device learned (`POST /v1/learning/observations`) and of an edited text
/// (`…/edit`): what becomes a mapping, what only a word in the dictionary, what is refused, and that the device is
/// told. All text here is made up.
@MainActor
@Suite struct HubLearningRuleTests {
    private func observe(_ hub: HubFixture, _ pairs: [CorrectionPair], dictationID: UUID? = nil,
                         id: UUID? = nil) async throws -> LearningObservationsResponse {
        let body = LearningObservations(pairs: pairs, dictationID: dictationID, id: id)
        return try decode(LearningObservationsResponse.self, try await hub.post(HubPath.learningObservations, body))
    }

    private func pair(_ wrong: String, _ right: String) -> CorrectionPair { CorrectionPair(wrong: wrong, right: right) }

    @Test func everydayWordsHeardForANameOnlyTeachTheName() async throws {
        let hub = try HubFixture()
        // 你有 → Nio as a mapping would rewrite every 你有: only the name is kept, as a word of the dictionary.
        let answer = try await observe(hub, [pair("你有", "Nio"), pair("你好", "Nio")])
        #expect(answer.accepted == 0 && answer.refused == [] && answer.terms == ["Nio"])
        #expect(hub.service.learning.pairs.isEmpty)
        let vocabulary = hub.service.vocabulary
        // A learned word (WL-7): tagged as learned, never one of the user's own, so the prompt weighs it below
        // every word the user chose and it is not among the words that make later fixes easier to accept.
        #expect(vocabulary.words.contains("Nio") && vocabulary.learned == ["Nio"])
        #expect(!hub.service.words.ownWords.contains("Nio") && hub.service.words.promptWords.learned == ["Nio"])
        #expect(!hub.service.words.promptWords.own.contains("Nio"))
        // However often it is sent, it never becomes a mapping, and raw text is left alone.
        for _ in 0..<3 { _ = try await observe(hub, [pair("你有", "Nio")]) }
        #expect(hub.service.learning.pairs.isEmpty)
        #expect(hub.service.words.applyConfirmed("你有没有空") == "你有没有空")
        #expect(hub.service.vocabulary.learned == ["Nio"])
    }

    @Test func aWordADeviceLearnedAloneIsLearnedAndTakenBackHereToo() async throws {
        let hub = try HubFixture()
        // The Mac learned "Cursor" without a mapping (a capital given to a word, which a bare pair cannot show)
        // and sends the word alone; then the user undid the edit, and it sends the word the other way round.
        let learned = try await observe(hub, [pair("", "Cursor"), pair("", "Nio")], dictationID: UUID(), id: UUID())
        #expect(learned.accepted == 0 && learned.refused == [] && learned.terms == ["Cursor", "Nio"])
        #expect(Set(hub.service.vocabulary.learned) == ["Cursor", "Nio"] && hub.service.learning.pairs.isEmpty)
        let back = try await observe(hub, [pair("Cursor", "")])
        #expect(back.accepted == 0 && back.refused == [])
        #expect(hub.service.vocabulary.learned == ["Nio"] && !hub.service.vocabulary.words.contains("Cursor"))
        // A word that was never learned that way stays: one of the user's own, or one a correction teaches.
        #expect(try await observe(hub, [pair("科德克斯", "Codex")]).accepted == 1)
        _ = try await observe(hub, [pair("Claude", ""), pair("Codex", "")])
        #expect(hub.service.vocabulary.words.contains("Claude") && hub.service.vocabulary.words.contains("Codex"))
        // Sent alone, a word must read like a name: not everyday text, a number or a secret.
        let odd = [pair("", "password"), pair("", "一百"), pair("", "the"), pair("", "sk-proj-" + "a1b2c3d4e5f6g7h8i9j0")]
        let refused = try await observe(hub, odd)
        #expect(refused.refused == odd && refused.terms == nil)
        #expect(hub.service.vocabulary.learned == ["Nio"])
        // It survives a restart as a learned word (it is kept with the corrections).
        let restarted = HubService(folder: hub.folder, asr: hub.asr, polisher: hub.polisher, rateLimit: 1_000)
        #expect(restarted.vocabulary.learned == ["Nio"] && !restarted.words.ownWords.contains("Nio"))
    }

    @Test(arguments: [["有效", "无效"], ["合法", "非法"], ["已婚", "未婚"], ["可行", "不行"], ["有关", "无关"], ["无线", "有线"],
                      ["不行", "步行"], ["周五", "周日"], ["星期三", "星期天"], ["十一月", "十月"], ["十一点", "十点"],
                      ["三个月", "上个月"], ["升级", "降级"], ["增产", "减产"], ["广州", "杭州"], ["小明", "小红"],
                      ["Eric", "Erin"], ["GitHub", "GitLab"], ["Tuesday", "Thursday"], ["金币", "硬币"], ["yin币", "硬币"]])
    func meaningChangesAreRefusedHoweverOftenTheyAreSent(_ sides: [String]) async throws {
        // WL-1, WL-2, WL-3: a number, a date, a negation or an opposite that changed, another name or another
        // word. The hub polishes for every device, so it must never learn to rewrite these.
        let hub = try HubFixture()
        let change = pair(sides[0], sides[1])
        for _ in 0..<3 {
            let answer = try await observe(hub, [change])
            #expect(answer.accepted == 0 && answer.refused == [change] && answer.terms == nil)
        }
        #expect(hub.service.learning.pairs.isEmpty && hub.service.vocabulary.words == Vocabulary.defaults)
        let said = "这个\(sides[0])的事"
        #expect(hub.service.words.applyConfirmed(said) == said && hub.service.words.promptPairs(for: said).isEmpty)
    }

    @Test func aMappingADeviceLearnedInASentenceIsAMappingHere() async throws {
        // The segmenter reads 斯威夫特 as one word when it stands alone, and as four characters in the sentence
        // the device learned it from. The hub cannot see the sentence: it takes the pair as the device did, so
        // the two do not end up with a mapping on one side and only a word on the other.
        let hub = try HubFixture()
        let answer = try await observe(hub, [pair("斯威夫特", "Swift"), pair("科德克斯", "Codex")])
        #expect(answer.accepted == 2 && answer.refused == [] && answer.terms == nil)
        #expect(Set(hub.service.learning.pairs.map(\.wrong)) == ["斯威夫特", "科德克斯"])
        // One person's name for another's is refused, also towards a name the user could have in the dictionary.
        let names = try await observe(hub, [pair("Jason", "Martin"), pair("Dustin", "Martin")])
        #expect(names.accepted == 0 && names.refused?.count == 2)
    }

    @Test(arguments: [["他不来", "Tableau"], ["你要死", "Neos"], ["他给我", "Tagger"]])
    func everydayWordsInARowNeverBecomeAMapping(_ sides: [String]) async throws {
        // WL-4: three one-character words are not the syllables of a name. Only the name is kept, as a learned word.
        let hub = try HubFixture()
        for _ in 0..<3 { _ = try await observe(hub, [pair(sides[0], sides[1])]) }
        #expect(hub.service.learning.pairs.isEmpty && hub.service.vocabulary.learned == [sides[1]])
        let said = "今天\(sides[0])了"
        #expect(hub.service.words.applyConfirmed(said) == said)
    }

    @Test func aLearnedWordDoesNotMakeLaterCorrectionsEasier() async throws {
        // WL-5: only the user's own words lower the bar. "Lavoben" learned without a mapping is not one of them.
        let hub = try HubFixture()
        #expect(try await observe(hub, [pair("", "Lavoben")]).terms == ["Lavoben"])
        let later = try await observe(hub, [pair("labels", "Lavoben"), pair("lavoben", "Lavoben")])
        #expect(later.accepted == 0 && later.refused?.count == 2)
        // Once the user has it as their own word, the fix towards it is learned, as a hint for the model: the
        // everyday word "labels" is never rewritten in text typed without it.
        let before = hub.service.vocabulary
        _ = try hub.service.updateVocabulary(VocabularyUpdate(words: before.words, expectedRevision: before.revision))
        #expect(hub.service.words.ownWords.contains("Lavoben") == false)
        _ = try hub.service.updateVocabulary(VocabularyUpdate(words: before.words.filter { $0 != "Lavoben" },
                                                              expectedRevision: hub.service.vocabulary.revision))
        _ = try hub.service.updateVocabulary(VocabularyUpdate(words: ["Lavoben"] + hub.service.vocabulary.words,
                                                              expectedRevision: hub.service.vocabulary.revision))
        #expect(hub.service.words.ownWords.contains("Lavoben"))
        for _ in 0..<2 { #expect(try await observe(hub, [pair("labels", "Lavoben")]).accepted == 1) }
        #expect(hub.service.learning.pairs.map(\.count) == [2])
        #expect(hub.service.words.applyConfirmed("put the labels in the doc") == "put the labels in the doc")
        #expect(hub.service.words.promptPairs(for: "put the labels in the doc") == [pair("labels", "Lavoben")])
    }

    @Test func aCorrectionCountsOnceForADeviceRecordAlsoAfterARestart() async throws {
        // WL-10: for a dictation the Mac did itself, the observation carries the Mac's own record id. The hub
        // keeps the ids with its corrections, so the same observation sent again after its answer was lost is
        // not counted twice, also when the hub restarted in between and no longer remembers the observation's id.
        let hub = try HubFixture()
        let record = UUID(), id = UUID()
        #expect(try await observe(hub, [pair("Open Air", "OpenAI")], dictationID: record, id: id).accepted == 1)
        let restarted = HubService(folder: hub.folder, asr: hub.asr, polisher: hub.polisher, rateLimit: 1_000)
        let again = restarted.observe(LearningObservations(pairs: [pair("Open Air", "OpenAI")], dictationID: record, id: id))
        #expect(again.accepted == 1)
        #expect(restarted.learning.pairs.map(\.count) == [1])
        #expect(restarted.words.applyConfirmed("open air 的账单") == "open air 的账单")
    }

    @Test func anObservationsIDIsRememberedAcrossARestart() async throws {
        // An observation without a record has only its own id to be told apart by. The hub keeps the ids it
        // answered on disk, so one sent again after a restart is still answered as then and not counted twice.
        let hub = try HubFixture()
        let id = UUID()
        #expect(try await observe(hub, [pair("Open Air", "OpenAI")], id: id).accepted == 1)
        let restarted = HubService(folder: hub.folder, asr: hub.asr, polisher: hub.polisher, rateLimit: 1_000)
        let again = restarted.observe(LearningObservations(pairs: [pair("Open Air", "OpenAI")], id: id))
        // The count it gave then. What it refused is not named: the words are not kept with the id.
        #expect(again == LearningObservationsResponse(accepted: 1, id: id))
        #expect(restarted.learning.pairs.map(\.count) == [1])
        // Ids and counts only.
        let file = try String(contentsOf: hub.folder.file(HubService.observedFile), encoding: .utf8)
        #expect(file.contains(id.uuidString) && !file.contains("OpenAI") && !file.contains("Open Air"))
        // Another id is another observation.
        #expect(restarted.observe(LearningObservations(pairs: [pair("Open Air", "OpenAI")], id: UUID())).accepted == 1)
        #expect(restarted.learning.pairs.map(\.count) == [2])
        // It says which version it is: a device offers an updated hub once more what it turned down before.
        #expect(HubService.version == "1.3.0")
    }

    @Test func theReverseOfAPairIsOnlyEverACountDown() async throws {
        let hub = try HubFixture()
        // Sent backwards without the pair being there: a name turned into words, a word into a number. Refused.
        let backwards = [pair("Nio", "你有"), pair("一版", "一百"), pair("Nick", "立刻")]
        let refused = try await observe(hub, backwards)
        #expect(refused.accepted == 0 && refused.refused == backwards && refused.terms == nil)
        #expect(hub.service.learning.pairs.isEmpty)
        #expect(hub.service.vocabulary.words == Vocabulary.defaults)

        // A mapping the hub has, sent backwards: counted down, as the device asked.
        #expect(try await observe(hub, [pair("科德克斯", "Codex")]).accepted == 1)
        #expect(try await observe(hub, [pair("科德克斯", "Codex")]).accepted == 1)
        #expect(hub.service.learning.pairs.map(\.count) == [2])
        let down = try await observe(hub, [pair("Codex", "科德克斯")])
        #expect(down.accepted == 1 && down.refused == [])
        #expect(hub.service.learning.pairs.map(\.count) == [1])
        _ = try await observe(hub, [pair("Codex", "科德克斯")])
        #expect(hub.service.learning.pairs.isEmpty)
        // Gone: the same pair backwards is refused again, it does not start a mapping of its own.
        #expect(try await observe(hub, [pair("Codex", "科德克斯")]).accepted == 0)
        #expect(hub.service.learning.pairs.isEmpty)
    }

    @Test func aNumberIsNeverTheWrongSideOfAMapping() async throws {
        let hub = try HubFixture()
        let answer = try await observe(hub, [pair("一百", "一版"), pair("twenty", "Trenty")])
        #expect(answer.accepted == 0 && answer.refused?.count == 2)
        #expect(hub.service.learning.pairs.isEmpty)
        #expect(hub.service.words.applyConfirmed("转一百块给他") == "转一百块给他")
    }

    @Test func theAnswerNamesWhatWasNotTaken() async throws {
        let hub = try HubFixture(words: ["音币"])
        let answer = try await observe(hub, [pair("金币", "音币"), pair("不同意", "同意"), pair(" ", "x"),
                                             pair("Open Air", "OpenAI")])
        #expect(answer.accepted == 2)
        #expect(answer.refused == [pair("不同意", "同意"), pair(" ", "x")])
        #expect(Set(hub.service.learning.pairs.map(\.wrong)) == ["金币", "Open Air"])
        // More mappings than one event takes: the rest is named too, so the device can say so.
        let many = [pair("Martn", "Martin"), pair("Jhn", "John"), pair("Petr", "Peter"), pair("Lucs", "Lucas")]
        let second = try await observe(hub, many)
        #expect(second.accepted == 3 && second.refused == [pair("Lucs", "Lucas")])
    }

    @Test func aDictionaryWordIsEasierToLearnTowards() async throws {
        let hub = try HubFixture(words: ["音币"])
        // Two made-up names in the hub's dictionary.
        let before = hub.service.vocabulary
        _ = try hub.service.updateVocabulary(VocabularyUpdate(words: ["Lavoben", "Marlo"] + before.words,
                                                              expectedRevision: before.revision))
        // A fix towards one of them may sound less alike, and a plain capital counts. Lavuben is not in the
        // dictionary, and sounds no more like "labels" than Lavoben does.
        let answer = try await observe(hub, [pair("labels", "Lavoben"), pair("marlo", "Marlo"), pair("labels", "Lavuben")])
        #expect(answer.accepted == 2 && answer.refused == [pair("labels", "Lavuben")])
        #expect(Set(hub.service.learning.pairs.map(\.right)) == ["Lavoben", "Marlo"])
        // Two Chinese words that only sound close are a fix towards the user's own word (音币 is one), not
        // towards any word, and not when a changed syllable sounds nothing like the one it replaced.
        let han = try await observe(hub, [pair("金币", "音币"), pair("金币", "硬币"), pair("日元", "美元")])
        #expect(han.accepted == 1 && han.refused == [pair("金币", "硬币"), pair("日元", "美元")])
    }

    @Test func anObservationSentAgainIsNotCountedTwice() async throws {
        let hub = try HubFixture(words: ["音币"])
        let id = UUID()
        let first = try await observe(hub, [pair("金币", "音币")], id: id)
        #expect(first.accepted == 1 && first.id == id)
        // Its answer was lost on the way and the device sent it again: the same answer, the same count.
        let again = try await observe(hub, [pair("金币", "音币")], id: id)
        #expect(again == first)
        #expect(hub.service.learning.pairs.map(\.count) == [1])
        // Another observation of the same pair is another fix.
        #expect(try await observe(hub, [pair("金币", "音币")], id: UUID()).accepted == 1)
        #expect(hub.service.learning.pairs.map(\.count) == [2])
        // Without an id nothing is remembered (a device from before ids).
        #expect(try await observe(hub, [pair("金币", "音币")]).id == nil)
        #expect(hub.service.learning.pairs.map(\.count) == [3])
    }

    @Test func editsAreComparedWithWhatTheHubDelivered() async throws {
        let hub = try HubFixture()
        hub.polisher.answer = { text, _ in text }
        hub.asr.reply = .text("问一下 Martn 这个 Open Air 的账单")
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        func edit(_ text: String) async throws -> [CorrectionPair] {
            try decode(EditResponse.self, try await hub.post(HubPath.edit(original.id), EditRequest(text: text))).learned
        }
        // Another name typed on the way teaches nothing, and is not what the next edit is compared with: the
        // wrong side of a correction is always text the hub typed.
        #expect(try await edit("问一下 Marvn 这个 Open Air 的账单") == [])
        #expect(try await edit("问一下 Martin 这个 Open Air 的账单") == [pair("Martn", "Martin")])
        // A fix fixed again builds on what the first one taught.
        #expect(try await edit("问一下 Martin 这个 Open AI 的账单") == [pair("Open Air", "Open AI")])
        #expect(try await edit("问一下 Martin 这个 OpenAI 的账单") == [pair("Open Air", "OpenAI")])
        #expect(Set(hub.service.learning.pairs.map(\.pair)) == [pair("Martn", "Martin"), pair("Open Air", "OpenAI")])
        // The text as delivered again: what its edits taught is taken back.
        #expect(try await edit("问一下 Martn 这个 Open Air 的账单") == [])
        #expect(hub.service.learning.pairs.isEmpty)
    }

    @Test func correctionsStoredByAnOlderVersionAreNotUsedAnyMore() async throws {
        // The version before this one learned a weekday, a negation, another place, an everyday phrase for a
        // name and a single character as mappings. They are still in the hub's learning.json after an update.
        let hub = try HubFixture(words: ["音币"])
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        func item(_ wrong: String, _ right: String, _ source: LearnedCorrection.Source = .otherApp) -> LearnedCorrection {
            LearnedCorrection(pair: pair(wrong, right), count: 5, firstSeen: day, lastSeen: day, source: source, addedTerm: false)
        }
        let old = [item("周五", "周日"), item("有效", "无效"), item("广州", "杭州"), item("他不来", "Tableau"), item("先", "西安"),
                   item("小明", "小红"), item("Eric", "Erica")]
        let kept = [item("引必", "音币"), item("金币", "音币"), item("科德克斯", "Codex")]
        #expect(hub.folder.store.write(LearningBook(items: old + kept + [item("图型", "图形", .imported)]),
                                       to: HubDataFolder.File.learning))
        let restarted = HubService(folder: hub.folder, asr: hub.asr, polisher: hub.polisher, rateLimit: 1_000)
        // Neither put before the model nor written into text, however often they were fixed.
        for said in ["帮我订周五去广州的机票", "这个方法有效，今天他不来", "我先去吃饭，先生你好", "问一下小明和 Eric"] {
            #expect(restarted.words.promptPairs(for: said).isEmpty, "\(said)")
            #expect(restarted.words.applyConfirmed(said) == said)
        }
        // What today's rules would learn is used as before; what the user imported is theirs.
        #expect(restarted.words.applyConfirmed("引必和图型，用科德克斯") == "音币和图形，用Codex")
        #expect(restarted.words.promptPairs(for: "看看金币") == [pair("金币", "音币")])
        #expect(restarted.words.applyConfirmed("看看金币") == "看看金币")
        // They stay in the book and in the list devices get (marked there), so nothing is lost and the user
        // can delete them; the hub says how many it does not use.
        #expect(restarted.words.unusedCorrections == old.count && restarted.learning.pairs.count == old.count + kept.count + 1)
        // A correction learned towards a dictionary word is judged without it once the word is gone.
        let before = restarted.vocabulary
        _ = try restarted.updateVocabulary(VocabularyUpdate(words: before.words.filter { $0 != "音币" }, expectedRevision: before.revision))
        #expect(restarted.words.promptPairs(for: "看看金币").isEmpty && restarted.words.unusedCorrections == old.count + 1)
    }

    @Test func aCapitalIsLearnedTheSecondTimeAndAHalfTypedNameLeavesNothing() async throws {
        let hub = try HubFixture()
        hub.polisher.answer = { text, _ in text }
        func dictate(_ text: String) async throws -> DictationResult {
            hub.asr.reply = .text(text)
            return try decode(DictationResult.self, try await hub.dictate(dictation()))
        }
        func edit(_ id: UUID, _ text: String) async throws {
            _ = try decode(EditResponse.self, try await hub.post(HubPath.edit(id), EditRequest(text: text)))
        }
        // A capital given to an everyday word once is only noted: as often style as a name.
        let first = try await dictate("我用 cursor 写代码")
        try await edit(first.id, "我用 Cursor 写代码")
        #expect(!hub.service.vocabulary.words.contains("Cursor") && hub.service.words.book.sightings.map(\.term) == ["Cursor"])
        // In another dictation again: a word of the dictionary, learned.
        let second = try await dictate("再用 cursor 改一下")
        try await edit(second.id, "再用 Cursor 改一下")
        #expect(hub.service.vocabulary.learned == ["Cursor"] && hub.service.words.book.sightings.isEmpty)

        // A name typed with a pause: its first letters are a word for a moment, then they are not.
        let third = try await dictate("用克劳德写")
        try await edit(third.id, "用 Cla 写")
        #expect(hub.service.vocabulary.learned.contains("Cla"))
        try await edit(third.id, "用 Claude 写")
        #expect(!hub.service.vocabulary.words.contains("Cla") && hub.service.vocabulary.learned == ["Cursor"])
        // The whole change is what is learned, from what the hub delivered.
        #expect(hub.service.learning.pairs.map(\.pair) == [pair("克劳德", "Claude")])
    }

    @Test func anEditThatFixesManyWordsTeachesThemAll() async throws {
        let hub = try HubFixture()
        hub.polisher.answer = { text, _ in text }
        hub.asr.reply = .text("Open Air 和 Martn 和 Cloud Code 和 Iphone 和 Word press，这个你有也试试")
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        let text = "OpenAI 和 Martin 和 Claude Code 和 iPhone 和 WordPress，这个 Nio 也试试"
        let edited = try decode(EditResponse.self, try await hub.post(HubPath.edit(original.id), EditRequest(text: text)))
        #expect(edited.learned == [pair("Open Air", "OpenAI"), pair("Martn", "Martin"), pair("Cloud Code", "Claude Code"),
                                   pair("Iphone", "iPhone"), pair("Word press", "WordPress")])
        #expect(hub.service.learning.pairs.count == 5)
        // The name heard as everyday words is in the dictionary as a learned word, with no mapping.
        #expect(hub.service.vocabulary.words.contains("Nio") && hub.service.vocabulary.learned.contains("Nio"))
        #expect(!hub.service.learning.pairs.contains { $0.right == "Nio" })
    }
}
