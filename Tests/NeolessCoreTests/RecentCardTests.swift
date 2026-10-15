import Foundation
import Testing
@testable import NeolessCore

@Suite struct RecentCardEmptyTests {
    @Test func aNewUserIsToldNothingWasDictatedYet() {
        // With or without 保存历史: the latest result stays in the card either way.
        for keeps in [true, false] {
            let empty = RecentCard.Empty(everDictated: false, keepsHistory: keeps)
            #expect(empty == .firstUse)
            #expect(empty.title == "还没有听写")
            #expect(!empty.linksToSettings)
        }
    }

    @Test func historyOffSaysSoBesideFiguresThatGoOnCounting() {
        // 累计听写 says 1,662 次 beside the card: it must not say 还没有听写.
        let empty = RecentCard.Empty(everDictated: true, keepsHistory: false)
        #expect(empty == .historyOff)
        #expect(empty.title == "历史记录已关闭")
        #expect(empty.message == "新的听写只在这里留最近一次")
        #expect(empty.linksToSettings)
    }

    @Test func clearedOrExpiredHistorySaysItIsEmpty() {
        // Cleared by hand, or every record older than 30 days: true of both.
        let empty = RecentCard.Empty(everDictated: true, keepsHistory: true)
        #expect(empty == .nothingKept)
        #expect(empty.title == "历史记录是空的")
        #expect(empty.message == "说完的文字会留在这里")
        #expect(!empty.linksToSettings)
    }

    @Test func onlyANewUserReadsThatNothingWasDictated() {
        for empty in RecentCard.Empty.allCases where empty != .firstUse {
            #expect(!empty.title.contains("还没有"))
            #expect(!empty.message.contains("还没有"))
        }
        // Short, plain, and no full stop on a line that stands alone.
        for empty in RecentCard.Empty.allCases {
            #expect(empty.title.count <= 8)
            #expect(empty.message.count <= 14)
            #expect(!empty.message.hasSuffix("。"))
        }
    }

    @Test func theOffLineIsAboutNewDictations() {
        // Results from before the switch was turned off may be listed above the line: it says nothing
        // about how many the card holds.
        #expect(RecentCard.historyOffLine == "历史记录已关闭，新的听写只留最近一次。")
        #expect(!RecentCard.historyOffLine.contains("这里只留"))
    }
}

@Suite struct RecentCardFootnoteTests {
    private let latest = UUID()
    private let earlier = UUID()

    private func pick(learnedFrom: UUID? = nil, learnedAgo: TimeInterval? = nil, unseen: UUID? = nil,
                      hasLearned: Bool = true) -> RecentCard.Footnote? {
        RecentCard.Footnote.pick(for: latest, learnedFrom: learnedFrom, learnedAgo: learnedAgo, unseen: unseen,
                                 hasLearned: hasLearned)
    }

    private func pick(notedFrom: UUID?, notedAgo: TimeInterval?, learnedFrom: UUID? = nil, learnedAgo: TimeInterval? = nil,
                      unseen: UUID? = nil, hasLearned: Bool = true) -> RecentCard.Footnote? {
        RecentCard.Footnote.pick(for: latest, learnedFrom: learnedFrom, learnedAgo: learnedAgo, unseen: unseen,
                                 hasLearned: hasLearned, notedFrom: notedFrom, notedAgo: notedAgo)
    }

    @Test func aSwapOnlyRememberedIsSaidLikeAFixLearned() {
        // Made in this result: for as long as it is the latest. In another: for five minutes.
        #expect(pick(notedFrom: latest, notedAgo: 2) == .noted)
        #expect(pick(notedFrom: latest, notedAgo: 3_600) == .noted)
        #expect(pick(notedFrom: earlier, notedAgo: 120) == .noted)
        #expect(pick(notedFrom: earlier, notedAgo: 300) == nil)
        // Nothing learned yet: once it is no longer news, the hint is back.
        #expect(pick(notedFrom: earlier, notedAgo: 300, hasLearned: false) == .editHint)
        #expect(pick(notedFrom: latest, notedAgo: 5, hasLearned: false) == .noted)
        // A result typed where nothing can be read says so before news from another result.
        #expect(pick(notedFrom: earlier, notedAgo: 60, unseen: latest) == .unseen)
        #expect(pick(notedFrom: latest, notedAgo: 60, unseen: latest) == .noted)
        // Nothing remembered: as before.
        #expect(pick(notedFrom: nil, notedAgo: nil) == nil)
    }

    @Test func ofAFixAndASwapTheLaterOneIsSaid() {
        // A word learned, then a swap remembered a minute later; and the other way round.
        #expect(pick(notedFrom: latest, notedAgo: 10, learnedFrom: latest, learnedAgo: 70) == .noted)
        #expect(pick(notedFrom: latest, notedAgo: 70, learnedFrom: latest, learnedAgo: 10) == .learned)
        // One edit that did both: what was learned (the swap has its own line in the log).
        #expect(pick(notedFrom: latest, notedAgo: 10, learnedFrom: latest, learnedAgo: 10) == .learned)
        #expect(pick(notedFrom: latest, notedAgo: 10, learnedFrom: latest, learnedAgo: 10.5) == .learned)
        // A swap remembered here, and an old fix from another result that is no longer said.
        #expect(pick(notedFrom: latest, notedAgo: 10, learnedFrom: earlier, learnedAgo: 900) == .noted)
        #expect(pick(notedFrom: earlier, notedAgo: 900, learnedFrom: latest, learnedAgo: 10) == .learned)
    }

    @Test func aFixLearnedFromThisResultIsSaidForAsLongAsItIsTheLatest() {
        #expect(pick(learnedFrom: latest, learnedAgo: 2) == .learned)
        #expect(pick(learnedFrom: latest, learnedAgo: 3_600) == .learned)
    }

    @Test func aFixLearnedFromAnotherResultIsSaidForFiveMinutes() {
        #expect(pick(learnedFrom: earlier, learnedAgo: 120) == .learned)
        #expect(pick(learnedFrom: earlier, learnedAgo: 299) == .learned)
        #expect(pick(learnedFrom: earlier, learnedAgo: 300) == nil)
        // One taught in the dictionary page's own way, from no result at all.
        #expect(pick(learnedFrom: nil, learnedAgo: 10) == .learned)
        #expect(pick(learnedFrom: nil, learnedAgo: 600) == nil)
    }

    @Test func aResultTypedWhereNothingCanBeReadSaysSoBeforeOlderNews() {
        // A word fixed in one app was learned two minutes ago; this dictation then went into an app whose
        // field cannot be read. The line under it is about this result, not "已记住" from the other one.
        #expect(pick(learnedFrom: earlier, learnedAgo: 120, unseen: latest) == .unseen)
        #expect(pick(learnedFrom: nil, learnedAgo: 5, unseen: latest) == .unseen)
        #expect(pick(unseen: latest) == .unseen)
        // Before anything was ever learned, too: it comes before the hint.
        #expect(pick(unseen: latest, hasLearned: false) == .unseen)
    }

    @Test func aFixMadeHereOnAnUnreadableResultIsStillSaid() {
        // It could not be seen where it was typed, and was then fixed in neoless itself: that was learned.
        #expect(pick(learnedFrom: latest, learnedAgo: 30, unseen: latest) == .learned)
    }

    @Test func anotherResultsUnreadableFieldSaysNothingHere() {
        #expect(pick(unseen: earlier) == nil)
        #expect(pick(learnedFrom: earlier, learnedAgo: 60, unseen: earlier) == .learned)
    }

    @Test func theHintStaysUntilTheFirstCorrectionIsLearned() {
        #expect(pick(hasLearned: false) == .editHint)
        #expect(pick(hasLearned: true) == nil)
        // An old correction that was since forgotten: the hint is back.
        #expect(pick(learnedFrom: earlier, learnedAgo: 900, hasLearned: false) == .editHint)
    }

    @Test func aClockSetBackDoesNotHideWhatWasJustLearned() {
        #expect(pick(learnedFrom: earlier, learnedAgo: -40) == .learned)
    }
}
