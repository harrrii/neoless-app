import Foundation

// 今日概览's 最近听写 card: the choices on it that are words. What it says when it has no result to show,
// what it says while 保存历史 is off, and which one line goes under the latest result. Nothing here draws.

public enum RecentCard {
    // MARK: Nothing to show

    /// Why the card has no result to show. The figures beside it count on their own (`UsageStats`), so the
    /// card only says "还没有听写" when they say so too.
    public enum Empty: Equatable, Sendable, CaseIterable {
        /// Nothing has ever been dictated.
        case firstUse
        /// 保存历史 is off, and nothing has been dictated since neoless started.
        case historyOff
        /// Dictations were counted and none is kept: history was cleared, or the last one is over 30 days old.
        case nothingKept

        /// - Parameters:
        ///   - everDictated: the stats have at least one day (`!UsageStats.days.isEmpty`).
        ///   - keepsHistory: 设置 › 通用 › 保存历史.
        public init(everDictated: Bool, keepsHistory: Bool) {
            if !everDictated {
                self = .firstUse
            } else {
                self = keepsHistory ? .nothingKept : .historyOff
            }
        }

        public var title: String {
            switch self {
            case .firstUse: return "还没有听写"
            case .historyOff: return "历史记录已关闭"
            case .nothingKept: return "历史记录是空的"
            }
        }

        public var message: String {
            switch self {
            case .firstUse, .nothingKept: return "说完的文字会留在这里"
            case .historyOff: return "新的听写只在这里留最近一次"
            }
        }

        /// The card is empty because of a switch: it offers the way to it.
        public var linksToSettings: Bool { self == .historyOff }
    }

    /// Under the results while 保存历史 is off. About new dictations, not about what the card holds: results
    /// from before the switch was turned off may still be listed above it.
    public static let historyOffLine = "历史记录已关闭，新的听写只留最近一次。"

    // MARK: Under the latest result

    /// The one quiet line under the latest result.
    public enum Footnote: Equatable, Sendable {
        /// "已记住：A → B", with 撤销.
        case learned
        /// "记下了：A → B，再这样改一次就记住", with 撤销: a swap made once, which is used for nothing yet.
        case noted
        /// The result was typed where neoless cannot read: a fix made there is not seen.
        case unseen
        /// Nothing has been learned yet: the text can be fixed right here.
        case editHint

        /// A correction learned from another result is still said under the latest one for this long.
        public static let fresh: TimeInterval = 5 * 60

        /// Which line goes under `record`, if any.
        ///
        /// A correction learned from this very result is said for as long as the result is the latest (it can
        /// be undone there). A result typed where nothing can be read says so before any news about another
        /// result: someone who has just fixed a word there must not read "已记住" and take it for that fix.
        ///
        /// A swap that was only remembered (made once) is said by the same rules. When there is both a
        /// correction and a remembered swap to say, the later one is said; of one and the same edit (within
        /// `sameEdit` of each other), what was learned.
        ///
        /// - Parameters:
        ///   - learnedFrom: the result the latest correction was learned from.
        ///   - learnedAgo: seconds since the latest correction was learned; nil when there is none to say.
        ///   - unseen: the result that was typed where its text cannot be read.
        ///   - hasLearned: at least one correction is in the list.
        ///   - notedFrom: the result the latest remembered swap was made in.
        ///   - notedAgo: seconds since that swap was remembered; nil when there is none to say.
        public static func pick(for record: UUID, learnedFrom: UUID?, learnedAgo: TimeInterval?, unseen: UUID?,
                                hasLearned: Bool, notedFrom: UUID? = nil, notedAgo: TimeInterval? = nil) -> Footnote? {
            func said(_ from: UUID?, _ ago: TimeInterval?) -> Bool {
                guard let ago else { return false }
                return from == record || (unseen != record && ago < fresh)
            }
            let learned = said(learnedFrom, learnedAgo), noted = said(notedFrom, notedAgo)
            if learned, noted, let learnedAgo, let notedAgo {
                return notedAgo + sameEdit < learnedAgo ? .noted : .learned
            }
            if learned { return .learned }
            if noted { return .noted }
            if unseen == record { return .unseen }
            return hasLearned ? nil : .editHint
        }

        /// What one edit taught and what it only remembered are recorded this close together.
        public static let sameEdit: TimeInterval = 2
    }
}
