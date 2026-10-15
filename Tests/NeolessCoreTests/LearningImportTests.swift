import Foundation
import Testing
@testable import NeolessCore

/// Corrections imported from a file (`LearningBook.importCorrections`) and the static-text override the user's own
/// instruction files and the polish eval use (`PolishPrompt.instructions(…, staticText:)`).
@Suite struct LearningImportTests {
    static let day0 = Date(timeIntervalSince1970: 1_790_000_000)

    func imported(_ wrong: String, _ right: String, count: Int = 1, at offset: TimeInterval = 0) -> ImportedCorrection {
        ImportedCorrection(pair: p(wrong, right), count: count, firstSeen: Self.day0.addingTimeInterval(offset - 3_600),
                           lastSeen: Self.day0.addingTimeInterval(offset))
    }

    @Test func importedPairsAreMarkedAndCountAsConfirmed() {
        var book = LearningBook()
        let outcome = book.importCorrections([imported("全限", "权限"), imported("Get Hub", "GitHub", count: 3)]) { $0 == "权限" }
        #expect(outcome.added == [p("全限", "权限"), p("Get Hub", "GitHub")])
        #expect(outcome.present.isEmpty && outcome.conflicting.isEmpty && outcome.full.isEmpty)
        #expect(book.items.allSatisfy { $0.source == .imported })
        // Fixed once in the file, still confirmed: at least `confirmedCount`, more when the file counted more.
        #expect(book.items.map(\.count) == [LearningPrompt.confirmedCount, 3])
        // The dictionary already had 权限; GitHub is a term learning adds (and forgetting the pair removes).
        #expect(book.items.map(\.addedTerm) == [false, true])
        #expect(book.items[0].firstSeen == Self.day0.addingTimeInterval(-3_600) && book.items[0].lastSeen == Self.day0)
        // Confirmed pairs apply without the model too (原样转写, a failed polish), and go into the prompt.
        #expect(LearningPrompt.applyConfirmed("3个账号全限不够", book: book) == "3个账号权限不够")
        #expect(LearningPrompt.pairs(for: "Get Hub 上的仓库", from: book) == [p("Get Hub", "GitHub")])
    }

    @Test func whatTheBookHasWins() {
        var book = LearningBook()
        _ = book.record([p("登陆", "登录")], source: .inApp, recordID: UUID(), now: Self.day0) { _ in false }
        _ = book.record([p("权限", "全线")], source: .otherApp, recordID: UUID(), now: Self.day0) { _ in false }
        _ = book.record([p("截止", "截至")], source: .otherApp, recordID: UUID(), now: Self.day0) { _ in false }
        let before = book.items
        let outcome = book.importCorrections([imported("登陆", "登录"), imported("全线", "权限"), imported("截止", "节制"),
                                              imported("you tube", "YouTube")]) { _ in false }
        #expect(outcome.present == [p("登陆", "登录")])
        // The reverse of a stored pair, and another fix of the same wrong form: the user's stays.
        #expect(outcome.conflicting == [p("全线", "权限"), p("截止", "节制")])
        #expect(outcome.added == [p("you tube", "YouTube")])
        #expect(Array(book.items.prefix(before.count)) == before)
        // Importing again changes nothing.
        let again = book
        let second = book.importCorrections([imported("you tube", "YouTube"), imported("YOU  TUBE", "youtube")]) { _ in false }
        #expect(second.added.isEmpty && second.present.count == 2 && book == again)
    }

    @Test func aFullBookTakesNoImportsAndEvictsNothing() {
        var book = LearningBook(items: (0..<LearningBook.maxItems).map { i in
            LearnedCorrection(pair: p("错\(i)", "对\(i)"), firstSeen: Self.day0, lastSeen: Self.day0, source: .inApp, addedTerm: false)
        })
        let before = book
        let outcome = book.importCorrections([imported("部属", "部署")]) { _ in false }
        #expect(outcome.full == [p("部属", "部署")] && outcome.added.isEmpty)
        #expect(book == before)
    }

    /// Imports made today do not use up the day's new corrections (`maxNewPerDay`).
    @Test func importsLeaveTheDailyCapAlone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var book = LearningBook()
        let today = (0..<LearningBook.maxNewPerDay).map {
            ImportedCorrection(pair: p("导\($0)", "入\($0)"), count: 1, firstSeen: Self.day0, lastSeen: Self.day0)
        }
        #expect(book.importCorrections(today) { _ in false }.added.count == LearningBook.maxNewPerDay)
        let event = book.record([p("金币", "硬币")], source: .inApp, recordID: UUID(), now: Self.day0.addingTimeInterval(60),
                                calendar: calendar) { _ in false }
        #expect(event.learned == [p("金币", "硬币")])
        // A user fix of an imported pair counts it again and makes it theirs.
        _ = book.record([p("导0", "入0")], source: .otherApp, recordID: UUID(), now: Self.day0.addingTimeInterval(90),
                        calendar: calendar) { _ in false }
        let item = book.items.first { $0.pair == p("导0", "入0") }
        #expect(item?.count == LearningPrompt.confirmedCount + 1 && item?.source == .otherApp)
    }

    @Test func importedSourceRoundTrips() throws {
        var book = LearningBook()
        _ = book.importCorrections([imported("Jason", "JSON")]) { _ in true }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(book)
        #expect(String(decoding: data, as: UTF8.self).contains("\"imported\""))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(LearningBook.self, from: data) == book)
    }

    // MARK: Static-text override

    @Test func staticTextReplacesOnlyTheStaticPart() {
        let words = ["GitHub", "权限"]
        let pairs = [p("全线", "权限")]
        for mode in [DictationMode.natural, .structured] {
            let live = PolishPrompt.instructions(for: mode, vocabulary: words, corrections: pairs)
            #expect(PolishPrompt.instructions(for: mode, vocabulary: words, corrections: pairs, staticText: nil) == live)
            #expect(PolishPrompt.instructions(for: mode, vocabulary: words, corrections: pairs,
                                              staticText: PolishPrompt.staticInstructions(for: mode)) == live)
            let variant = PolishPrompt.instructions(for: mode, vocabulary: words, corrections: pairs, staticText: "# 新指令\n只整理。")
            let section = PolishPrompt.hotwordsSection(vocabulary: words, corrections: pairs)!
            #expect(variant == "# 新指令\n只整理。\n\n" + section)
        }
        #expect(PolishPrompt.instructions(for: .natural, staticText: "只整理。") == "只整理。")
    }
}
