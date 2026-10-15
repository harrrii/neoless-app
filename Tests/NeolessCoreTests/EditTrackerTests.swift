import Testing
@testable import NeolessCore

/// Settles `text` and, like the app, commits what the extractor learned from. 硬币 is one of the user's words.
private func step(_ t: inout EditTracker, _ text: String, extractor: CorrectionExtractor = .init()) -> [CorrectionPair]? {
    guard case let .extract(inserted, edited) = t.settle(text) else { return nil }
    let found = extractor.extract(inserted: inserted, edited: edited, knownTerms: ["硬币"])
    if !found.isEmpty { t.commit(edited, over: inserted, understood: found.baseline) }
    return found.pairs
}

@Test func trackerExtractsAgainstPreviousBaseline() {
    var t = EditTracker(original: "看看金币是多少")
    #expect(t.settle("看看金币是多少") == .none)
    #expect(t.settle("看看硬币是多少") == .extract(inserted: "看看金币是多少", edited: "看看硬币是多少"))
    t.commit("看看硬币是多少", over: "看看金币是多少")
    #expect(t.baseline == "看看硬币是多少")
    #expect(t.settle("看看硬币是多少？") == .extract(inserted: "看看硬币是多少", edited: "看看硬币是多少？"))
}

@Test func trackerKeepsBaselineAcrossDeleteThenRetype() {
    var t = EditTracker(original: "看看金币是多少")
    #expect(t.settle("看看币是多少") == .none)
    #expect(t.baseline == "看看金币是多少")
    #expect(t.settle("看看硬币是多少") == .extract(inserted: "看看金币是多少", edited: "看看硬币是多少"))
}

@Test func trackerKeepsBaselineWhenAStepTeachesNothing() {
    // The IME commits 硬 first, then 币 after a pause: the half-finished step teaches nothing,
    // so the whole fix is compared with the delivered text.
    var t = EditTracker(original: "看看金币是多少")
    #expect(t.settle("看看硬是多少") == .extract(inserted: "看看金币是多少", edited: "看看硬是多少"))
    #expect(t.baseline == "看看金币是多少")
    #expect(t.settle("看看硬是多少") == .none)
    #expect(t.settle("看看硬币是多少") == .extract(inserted: "看看金币是多少", edited: "看看硬币是多少"))
}

@Test func trackerHalfFinishedImeFixIsLearnedWhole() {
    var t = EditTracker(original: "看看金币是多少")
    #expect(step(&t, "看看硬是多少") == [])
    #expect(t.baseline == "看看金币是多少")
    #expect(step(&t, "看看硬币是多少") == [CorrectionPair(wrong: "金币", right: "硬币")])
    #expect(t.baseline == "看看硬币是多少")
}

@Test func trackerComparesSpaceOnlyDeletion() {
    var t = EditTracker(original: "我们下周用 Open Air 的接口做个测试")
    t.commit("我们下周用 Open AI 的接口做个测试", over: "我们下周用 Open Air 的接口做个测试")
    #expect(t.settle("我们下周用 OpenAI 的接口做个测试")
        == .extract(inserted: "我们下周用 Open AI 的接口做个测试", edited: "我们下周用 OpenAI 的接口做个测试"))
    // Deleting letters still waits for the retype.
    #expect(t.settle("我们下周用 Open  的接口做个测试") == .none)
}

@Test func trackerTwoStepFixComposes() {
    // "Open Air" → "Open AI", a pause, then the space goes: the second step chains onto the first.
    var t = EditTracker(original: "我们下周用 Open Air 的接口做个测试")
    let first = step(&t, "我们下周用 Open AI 的接口做个测试") ?? []
    #expect(first == [CorrectionPair(wrong: "Open Air", right: "Open AI")])
    let second = step(&t, "我们下周用 OpenAI 的接口做个测试") ?? []
    #expect(LearningBook.chained(second, after: first) == [CorrectionPair(wrong: "Open Air", right: "OpenAI")])
}

@Test func trackerIgnoresStaleCommit() {
    var t = EditTracker(original: "Open Air 的账单")
    t.commit("OpenAI 的账单", over: "Open Air 的账单")
    t.commit("OpenAI 的账单。", over: "Open Air 的账单")
    #expect(t.baseline == "OpenAI 的账单")
}

@Test func trackerUndoRedoTeachesNothing() {
    var t = EditTracker(original: "Open Air 的账单")
    t.commit("OpenAI 的账单", over: "Open Air 的账单")
    t.commit("OpenAI 的账单。", over: "OpenAI 的账单")
    // Undo back to an earlier edited state, then redo.
    #expect(t.settle("OpenAI 的账单") == .none)
    #expect(t.baseline == "OpenAI 的账单")
    #expect(t.settle("OpenAI 的账单。") == .none)
}

@Test func trackerRetractsOnFullUndo() {
    var t = EditTracker(original: "Open Air 的账单")
    t.commit("OpenAI 的账单", over: "Open Air 的账单")
    #expect(t.settle("Open Air 的账单") == .retract)
    #expect(t.baseline == "Open Air 的账单")
    #expect(t.settle("Open Air 的账单") == .none)
}

@Test func deletionDetection() {
    #expect(EditTracker.isDeletion(from: "abcdef", to: "abef"))
    #expect(EditTracker.isDeletion(from: "abc", to: ""))
    #expect(!EditTracker.isDeletion(from: "abcdef", to: "abxf"))
    #expect(!EditTracker.isDeletion(from: "abc", to: "abc"))
    #expect(!EditTracker.isDeletion(from: "abcdef", to: "bcdf"))
    #expect(EditTracker.deletion(from: "Open AI", to: "OpenAI") == " ")
}
