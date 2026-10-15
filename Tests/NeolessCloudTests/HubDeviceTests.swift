import Foundation
import NeolessCore
import Testing
@testable import NeolessCloud

private let token = "dGVzdC10b2tlbi0xMjM0NTY3ODkwYWJjZGVmZ2hpams"
private let server = URL(string: "https://hub.example.com")!

private func health(asr: Bool = true, chatgpt: Bool = true, problem: String? = nil) -> HubHealth {
    HubHealth(version: "1.2.0", asr: .init(ready: asr, model: "Qwen3-ASR-0.6B-4bit"),
              chatgpt: .init(ready: chatgpt, account: chatgpt ? "a***@example.com" : nil, problem: problem), device: "Mac")
}

private func hubBody(_ status: Int, _ code: String, _ text: String = "出错了", retryable: Bool = false) -> HubError {
    .server(status: status, body: HubErrorBody(error: text, code: code, retryable: retryable))
}

@Suite struct HubPairingInputTests {
    @Test func serverAddressAsTyped() {
        #expect(HubPairing.server(from: "hub.example.com")?.absoluteString == "https://hub.example.com")
        #expect(HubPairing.server(from: " https://hub.example.com/ ")?.absoluteString == "https://hub.example.com")
        #expect(HubPairing.server(from: "HTTPS://Hub.example.com")?.absoluteString == "https://hub.example.com")
        #expect(HubPairing.server(from: "http://127.0.0.1:18800")?.absoluteString == "http://127.0.0.1:18800")
        // Plain http only for this Mac itself; no spaces, nothing empty.
        #expect(HubPairing.server(from: "http://hub.example.com") == nil)
        #expect(HubPairing.server(from: "") == nil)
        #expect(HubPairing.server(from: "hub example.com") == nil)
        #expect(HubPairing.server(from: "ftp://hub.example.com") == nil)
    }

    @Test func pastedLinkOrToken() throws {
        let link = try HubPairing(server: URL(string: "https://neo.example.com")!, token: token, name: "书房的 Mac").url.absoluteString
        let fromLink = try HubPairing(pasted: "  \(link)\n", server: server, name: "MacBook Air")
        #expect(fromLink.server.absoluteString == "https://neo.example.com")
        #expect(fromLink.name == "书房的 Mac")
        #expect(fromLink.token == token)

        // A link without a name gets this device's.
        let unnamed = try HubPairing(pasted: "neoless://pair?server=https%3A%2F%2Fneo.example.com&token=\(token)",
                                     server: server, name: "MacBook Air")
        #expect(unnamed.name == "MacBook Air")

        // A bare token pairs with the address in Settings.
        let bare = try HubPairing(pasted: token, server: server, name: "MacBook Air")
        #expect(bare.server == server && bare.token == token && bare.name == "MacBook Air")
        // With no address there, a token alone pairs with nothing (there is no default hub); a link still does.
        #expect(throws: HubProtocolError.noServer) { try HubPairing(pasted: token, server: nil, name: "Mac") }
        #expect(try HubPairing(pasted: link, server: nil, name: "Mac").server.absoluteString == "https://neo.example.com")
        #expect(throws: HubProtocolError.notPairingText) { try HubPairing(pasted: "你好", server: nil, name: "Mac") }
        #expect(HubProtocolError.noServer.errorDescription?.contains("服务器地址") == true)

        #expect(throws: HubProtocolError.notPairingText) { try HubPairing(pasted: "你好", server: server, name: "Mac") }
        #expect(throws: HubProtocolError.notPairingText) { try HubPairing(pasted: "short", server: server, name: "Mac") }
        #expect(throws: HubProtocolError.badServer) {
            try HubPairing(pasted: "neoless://pair?server=http%3A%2F%2Fevil.example&token=\(token)", server: server, name: "Mac")
        }
        #expect(HubProtocolError.notPairingText.errorDescription == "这不是配对链接，也不是设备密钥")
    }

    @Test func aLinksNameIsOneShortLine() throws {
        // A web page writes the link: its name is cut to what `pair --name` allows, on one line.
        var parts = URLComponents(string: "neoless://pair")!
        parts.queryItems = [URLQueryItem(name: "server", value: "https://neo.example.com"), URLQueryItem(name: "token", value: token),
                            URLQueryItem(name: "name", value: "MacBook”。\n\u{1B}[2J" + String(repeating: "这就是你现在的 Neo", count: 5))]
        let link = try HubPairing(url: parts.url!)
        #expect(link.name.count <= HubPairing.maxNameLength)
        #expect(!link.name.contains("\n") && !link.name.unicodeScalars.contains("\u{1B}"))
        #expect(link.name.hasPrefix("MacBook”。[2J"))
    }
}

@Suite struct HubStatusTests {
    @Test func textsForEveryState() {
        #expect(HubStatus.off.text == "已关闭，用本机处理")
        #expect(HubStatus.unpaired.text == "还没配对")
        #expect(HubStatus.checking.text == "正在连接 Neo…")
        #expect(HubStatus.connected(health()).text == "已连接 · 识别和整理都正常")
        #expect(HubStatus.connected(health(asr: false)).text == "已连接 · Neo 的识别暂时不可用")
        #expect(HubStatus.connected(health(chatgpt: false)).text == "已连接 · Neo 上的 ChatGPT 不可用")
        #expect(HubStatus.unreachable("连不上 Neo").text == "连不上 Neo，用本机处理")
        #expect(HubStatus.revoked.text == "配对已失效，请重新配对")

        #expect(HubStatus.off.short == nil && HubStatus.unpaired.short == nil)
        #expect(HubStatus.connected(health()).short == "用 Neo 处理")
        #expect(HubStatus.unreachable("没有网络").short == "连不上 Neo，用本机处理")
        #expect(HubStatus.revoked.short == "Neo 配对已失效")
    }

    @Test func detailsSayOnlyWhatTheRowDoesNot() {
        #expect(HubStatus.connected(health()).detail == nil)
        #expect(HubStatus.connected(health(chatgpt: false, problem: "ChatGPT 登录已过期")).detail == "ChatGPT 登录已过期。识别照常，整理用这台设备的 ChatGPT")
        #expect(HubStatus.connected(health(chatgpt: false)).detail == "Neo 上没有登录 ChatGPT。识别照常，整理用这台设备的 ChatGPT")
        // The hub's `problem` is the cause alone: what it means is said once, here.
        #expect(HubStatus.connected(health(chatgpt: false, problem: "Neo 还没登录 ChatGPT")).detail
                == "Neo 还没登录 ChatGPT。识别照常，整理用这台设备的 ChatGPT")
        // A failed model load: the next dictation tries again, and meanwhile the Neo polishes this device's transcript.
        #expect(HubStatus.connected(health(asr: false)).detail == "暂时用这台设备的识别结果，Neo 照常整理")
        #expect(HubStatus.unreachable("连不上 Neo").detail == nil)
        #expect(HubStatus.unreachable("Neo 没有响应，可能在睡眠或断网").detail == "Neo 没有响应，可能在睡眠或断网")
        #expect(HubStatus.revoked.detail != nil)
    }

    @Test func problemsAreSoftFactsForTheMenuBar() {
        #expect(!HubStatus.off.isProblem && !HubStatus.unpaired.isProblem && !HubStatus.checking.isProblem)
        #expect(!HubStatus.connected(health()).isProblem)
        #expect(HubStatus.connected(health(asr: false)).isProblem)
        #expect(HubStatus.unreachable("x").isProblem && HubStatus.revoked.isProblem)

        #expect(HubStatus.off.serviceFact == .off && HubStatus.unpaired.serviceFact == .off)
        #expect(HubStatus.checking.serviceFact == .connected && HubStatus.connected(health()).serviceFact == .connected)
        #expect(HubStatus.unreachable("x").serviceFact == .unreachable)
        #expect(HubStatus.revoked.serviceFact == .revoked)
        // Reached, but every recording is turned away: this Mac does the work, with its own login.
        #expect(HubStatus.connected(health(asr: false)).serviceFact == .cannotRecognize)
        // Its ChatGPT down, the Neo still recognises and types the original, which this Mac polishes with its login.
        #expect(HubStatus.connected(health(chatgpt: false)).serviceFact == .cannotPolish)
    }

    @Test func coversOnlyWhileTheNeoDoesTheWork() {
        #expect(HubStatus.checking.covers)
        #expect(HubStatus.connected(health()).covers)
        // This Mac's ChatGPT login counts again: setup, the expired-login hints.
        #expect(!HubStatus.connected(health(chatgpt: false)).covers)
        #expect(!HubStatus.connected(health(asr: false)).covers)
        // Whether the Neo recognises is a separate question (the home page's "Neo 识别").
        #expect(HubStatus.connected(health(chatgpt: false)).recognizes && HubStatus.checking.recognizes)
        #expect(!HubStatus.connected(health(asr: false)).recognizes && !HubStatus.unreachable("x").recognizes)
        #expect(!HubStatus.unreachable("连不上 Neo").covers)
        #expect(!HubStatus.revoked.covers)
        #expect(!HubStatus.off.covers && !HubStatus.unpaired.covers)
    }

    @Test func whatAFailedCallSaysAboutTheNeo() {
        #expect(HubStatus.after(hubBody(401, HubErrorCode.unauthorized)) == .revoked)
        #expect(HubStatus.after(hubBody(403, HubErrorCode.forbidden)) == .revoked)
        #expect(HubStatus.after(HubError.unreachable) == .unreachable("连不上 Neo"))
        #expect(HubStatus.after(HubError.offline) == .unreachable("没有网络"))
        #expect(HubStatus.after(HubError.connectionLost) == .unreachable("和 Neo 的连接断了"))
        // Cloudflare's own pages: asleep, or turned away on the way.
        #expect(HubStatus.after(HubError.server(status: 530, body: nil)) == .unreachable("Neo 没有响应，可能在睡眠或断网"))
        #expect(HubStatus.after(HubError.server(status: 403, body: nil)) == .unreachable("请求被网络拦下了（403）"))
        // Reached: still working (524), slow, or answering with its own error.
        #expect(HubStatus.after(HubError.server(status: 524, body: nil)) == nil)
        #expect(HubStatus.after(HubError.timeout) == nil)
        #expect(HubStatus.after(hubBody(503, HubErrorCode.asrUnavailable, retryable: true)) == nil)
        #expect(HubStatus.after(HubError.badResponse) == nil)
        #expect(HubStatus.after(CancellationError()) == nil)
    }
}

@Suite struct HubDictationTests {
    let request = DictationRequest(mode: .natural, autoStructured: true, appName: "微信", localTranscript: nil,
                                   durationSeconds: 3, client: .mac, clientVersion: "1.2.0")

    private func result(raw: String, text: String = "") -> DictationResult {
        DictationResult(clientRecordingID: request.clientRecordingID, raw: raw, text: text, mode: .natural,
                        polished: !text.isEmpty, recognizer: .qwen3ASR)
    }

    @Test func theHubsTextWhenItHeardSomething() {
        let answer = result(raw: "明天开会", text: "明天开会。")
        #expect(HubDictation.next(answer, request: request, localTranscript: "明天开会") == .use(answer))
        #expect(HubDictation.next(answer, request: request, localTranscript: "") == .use(answer))
    }

    @Test func emptyHubResultFallsToThisDevicesTranscriptUnderTheSameID() {
        guard case .polish(let polish) = HubDictation.next(result(raw: " "), request: request, localTranscript: " 明天开会 ") else {
            Issue.record("expected a polish request")
            return
        }
        #expect(polish.text == "明天开会")
        #expect(polish.clientRecordingID == request.clientRecordingID)
        #expect(polish.mode == .natural && polish.autoStructured && polish.appName == "微信")
        #expect(polish.client == .mac && polish.durationSeconds == 3)
        #expect(HubDictation.next(result(raw: ""), request: request, localTranscript: "  ") == .nothingHeard)
    }

    @Test func theHubsReasonsAreSaidAsTheNeos() {
        #expect(HubDictation.reason(HubFallback(title: "已输入原文", reason: "ChatGPT 登录已失效")) == "Neo 上 ChatGPT 登录已失效")
        #expect(HubDictation.reason(HubFallback(title: "已输入原文", reason: "整理超时")) == "Neo 上整理超时")
        #expect(HubDictation.reason(HubFallback(title: "已输入原文", reason: "Neo 上没有登录 ChatGPT")) == "Neo 上没有登录 ChatGPT")
        #expect(HubDictation.reason(HubFallback(title: "已输入原文", reason: " ")) == "Neo 上没有整理")
        // Not this Mac's login: the home page offers no 重新登录 for it.
        #expect(HubDictation.reason(HubFallback(title: "", reason: PolishError.http(401, "").short)) != PolishError.http(401, "").short)
    }

    @Test func quietFallbackNotes() {
        #expect(HubDictation.fallbackNote(HubError.unreachable) == "连不上 Neo，用本机处理")
        #expect(HubDictation.fallbackNote(HubError.offline) == "没有网络，用本机处理")
        #expect(HubDictation.fallbackNote(HubError.timeout) == "Neo 处理超时，用本机处理")
        #expect(HubDictation.fallbackNote(PolishError.timeout) == "Neo 处理超时，用本机处理")
        #expect(HubDictation.fallbackNote(hubBody(401, HubErrorCode.unauthorized)) == "Neo 配对已失效，用本机处理")
        #expect(HubDictation.fallbackNote(hubBody(503, HubErrorCode.asrUnavailable, "识别服务没有启动")) == "识别服务没有启动，用本机处理")
        // The Neo's ChatGPT, not this Mac's: no 重新登录 hint for it.
        #expect(HubDictation.fallbackNote(hubBody(503, HubErrorCode.polishFailed, "ChatGPT 登录已过期")) == "Neo 上 ChatGPT 登录已过期，用本机处理")
        #expect(HubDictation.fallbackNote(hubBody(503, HubErrorCode.polishFailed, "整理超时")) == "Neo 上整理超时，用本机处理")
        #expect(HubDictation.fallbackNote(HubError.server(status: 502, body: nil)) == "Neo 没有响应，可能在睡眠或断网，用本机处理")
        #expect(HubDictation.fallbackNote(URLError(.badURL)) == "Neo 出错了，用本机处理")
    }

    @Test func notesSayWhatHappenedHere() {
        // 重新整理 without the Neo and without this device's own login: nothing was processed here.
        #expect(HubDictation.notRepolishedNote(HubError.unreachable) == "连不上 Neo，没有重新整理")
        #expect(HubDictation.notRepolishedNote(hubBody(503, HubErrorCode.polishFailed, "整理超时")) == "Neo 上整理超时，没有重新整理")
        // The Neo typed the original and this device polished it.
        #expect(HubDictation.polishedHereNote(HubFallback(title: "已输入原文", reason: "ChatGPT 登录已过期"))
                == "Neo 上 ChatGPT 登录已过期，用本机整理")
    }

    @Test func interactiveBudgetsStayUnderCloudflaresWait() {
        let t = HubTimeouts.interactive
        #expect(t.cap < HubClient.cloudflareWait)
        // A short dictation keeps its full budget; a ten-minute one is cut to the cap.
        #expect(t.dictation(durationSeconds: 10, audioBytes: 40_000) == HubTimeouts.standard.dictation(durationSeconds: 10, audioBytes: 40_000))
        #expect(t.dictation(durationSeconds: 600, audioBytes: 2_400_000) == HubTimeouts.interactiveCap)
    }
}

@Suite struct HubVocabularyTests {
    @Test func editsApplyInOrder() {
        let words = ["OpenAI", "Codex", "Martin"]
        #expect(HubVocabulary.applying([.add(["Claude"])], to: words) == ["Claude", "OpenAI", "Codex", "Martin"])
        // A word already there moves to the front; case does not make a second one.
        #expect(HubVocabulary.applying([.add(["codex"])], to: words) == ["codex", "OpenAI", "Martin"])
        #expect(HubVocabulary.applying([.remove("martin")], to: words) == ["OpenAI", "Codex"])
        #expect(HubVocabulary.applying([.add(["Claude"]), .remove("Claude")], to: words) == words)
        #expect(HubVocabulary.applying([], to: words) == words)
    }

    @Test func mirrorKeepsTermsLearnedHere() {
        let hub = VocabularySnapshot(words: ["OpenAI", "Codex", "硬币"], learned: ["硬币"], revision: "r1")
        #expect(HubVocabulary.mirrored(hub, localLearned: ["Claude", "codex"]) == ["Claude", "OpenAI", "Codex", "硬币"])
        #expect(HubVocabulary.mirrored(hub, localLearned: []) == hub.words)
    }

    @Test func firstSyncGivesTheHubThisDevicesOwnWordsAndRemovesNothing() {
        let edits = HubVocabulary.reconcile(local: ["Martin", "Codex", "Claude", "martin", "OpenAI"], localLearned: ["Claude"],
                                            base: nil, hub: ["OpenAI", "codex", "Figma"])
        #expect(edits == [.add(["Martin"])])
        #expect(HubVocabulary.reconcile(local: ["OpenAI"], localLearned: [], base: nil, hub: ["OpenAI", "Figma"]).isEmpty)
    }

    @Test func wordsAddedHereAreToldFromOtherChanges() {
        // A word added here reaches the hub after the corrections that were waiting (the outbox goes first), so
        // a correction learned towards it was judged there without it. After a sync that gave the hub new
        // words, the device offers what the hub lacks once more; a sync that only removed words does not.
        let added = HubVocabulary.reconcile(local: ["Cursor", "OpenAI"], localLearned: [], base: ["OpenAI"], hub: ["OpenAI"])
        #expect(added == [.add(["Cursor"])] && HubVocabulary.adds(added))
        let removed = HubVocabulary.reconcile(local: ["OpenAI"], localLearned: [], base: ["OpenAI", "Codex"], hub: ["OpenAI", "Codex"])
        #expect(removed == [.remove("Codex")] && !HubVocabulary.adds(removed))
        #expect(!HubVocabulary.adds([]) && !HubVocabulary.adds([.add([])]))
        // What is offered then: the corrections the hub does not hold, the latest first, each as its own observation.
        let seen = Date(timeIntervalSince1970: 1_791_398_700)
        let book = LearningBook(items: [("Curser", "Cursor"), ("Open Air", "OpenAI")].map {
            LearnedCorrection(pair: CorrectionPair(wrong: $0.0, right: $0.1), firstSeen: seen, lastSeen: seen, source: .otherApp, addedTerm: true)
        })
        let offer = HubLearning.resend(book, missing: [LearningBook.key(CorrectionPair(wrong: "Curser", right: "Cursor"))])
        #expect(offer.map(\.pairs) == [[CorrectionPair(wrong: "Curser", right: "Cursor")]] && offer[0].id != nil)
    }

    @Test func laterSyncsSendWhatChangedHereSinceTheLastOne() {
        let base = ["OpenAI", "Codex", "Martin", "硬币"]
        // Here: Claude added and Codex removed while the Neo slept; on the iPhone meanwhile: Martin removed, Figma added.
        let local = ["Claude", "OpenAI", "Martin", "硬币", "Cloud"]
        let hub = ["Figma", "OpenAI", "Codex", "硬币"]
        let edits = HubVocabulary.reconcile(local: local, localLearned: ["Cloud"], base: base, hub: hub)
        #expect(edits == [.add(["Claude"]), .remove("Codex")])
        // Both sides kept: the iPhone's removal and addition stand, this Mac's too.
        #expect(HubVocabulary.applying(edits, to: hub) == ["Claude", "Figma", "OpenAI", "硬币"])
        // Nothing changed here: nothing to send, whatever the hub did.
        #expect(HubVocabulary.reconcile(local: base, localLearned: [], base: base, hub: hub).isEmpty)
    }
}

@Suite struct HubLearningTests {
    let day = Date(timeIntervalSince1970: 1_791_398_700)

    private func item(_ wrong: String, _ right: String, _ count: Int, daysAgo: Double = 0) -> LearnedCorrection {
        let seen = day.addingTimeInterval(-daysAgo * 86_400)
        return LearnedCorrection(pair: CorrectionPair(wrong: wrong, right: right), count: count, firstSeen: seen, lastSeen: seen,
                                 source: .inApp, addedTerm: true)
    }

    @Test func mergedKeepsTheHigherCountAndAddsTheHubsOwn() {
        let local = LearningBook(items: [item("Open Air", "OpenAI", 1, daysAgo: 2), item("Cloud", "Claude", 3)])
        let entries = [
            LearningEntry(wrong: "open air", right: "openai", count: 4, lastSeen: day),
            LearningEntry(wrong: "引必", right: "音币", count: 2, lastSeen: day),
            LearningEntry(wrong: "", right: "x", count: 5, lastSeen: day),
        ]
        let merged = HubLearning.merged(local, hub: entries)
        #expect(merged.items.count == 3)
        #expect(merged.items[0].count == 4 && merged.items[0].lastSeen == day && merged.items[0].pair.right == "OpenAI")
        #expect(merged.items[1].count == 3)
        let added = merged.items[2]
        #expect(added.pair == CorrectionPair(wrong: "引必", right: "音币") && added.count == 2 && !added.addedTerm)
        // Confirmed on the Neo: typed as is here too.
        #expect(LearningPrompt.applyConfirmed("两百引必", book: merged) == "两百音币")
        #expect(HubLearning.merged(local, hub: []) == local)
    }

    @Test func forgottenHereIsNotUsedFromTheNeosListMeanwhile() {
        let entries = [
            LearningEntry(wrong: "open  air", right: "OpenAI", count: 3, lastSeen: day),
            LearningEntry(wrong: "Open Air", right: "Open AI", count: 1, lastSeen: day),
            LearningEntry(wrong: "苹果", right: "Apple", count: 2, lastSeen: day),
        ]
        // Matched as the Neo forgets: every pair with that wrong, ignoring case and spacing.
        #expect(HubLearning.without(forgotten: ["Open Air"], entries) == [entries[2]])
        #expect(HubLearning.without(forgotten: [], entries) == entries)
        #expect(HubLearning.without(forgotten: ["苹果", "open air"], entries).isEmpty)

        #expect(HubLearning.contains(entries, CorrectionPair(wrong: "open air", right: "openai")))
        #expect(!HubLearning.contains(entries, CorrectionPair(wrong: "OpenAI", right: "Open Air")))
    }

    @Test func seedGivesTheMostUsedInGroupsOfThree() {
        let items = (1...25).map { item("错\($0)", "对\($0)", $0) }
        let seed = HubLearning.seed(LearningBook(items: items))
        #expect(seed.count == 7)
        #expect(seed.allSatisfy { $0.pairs.count <= LearningBook.maxPairsPerEvent && $0.dictationID == nil })
        let pairs = seed.flatMap(\.pairs)
        #expect(pairs.count == LearningBook.maxNewPerDay)
        #expect(pairs.first == CorrectionPair(wrong: "错25", right: "对25"))
        #expect(HubLearning.seed(LearningBook()).isEmpty)
    }
}

@Suite struct HubOutboxTests {
    let a = CorrectionPair(wrong: "Open Air", right: "OpenAI")
    let b = CorrectionPair(wrong: "金币", right: "硬币")

    @Test func latestEditWinsAndForgettingDropsWaitingPairs() throws {
        var box = HubOutbox()
        #expect(box.isEmpty)
        let id = UUID()
        box.edit(id, text: "一")
        box.edit(id, text: "二")
        #expect(box.edits == [HubOutbox.Edit(id: id, text: "二")])
        box.observe([a, b], dictationID: id)
        box.observe([])
        box.forget("Open Air")
        box.forget("Open Air")
        #expect(box.observations == [LearningObservations(pairs: [b], dictationID: id)])
        #expect(box.forgotten == ["Open Air"])
        box.forget("金币")
        #expect(box.observations.isEmpty)
        // Saved with the app's data.
        #expect(try JSONDecoder().decode(HubOutbox.self, from: JSONEncoder().encode(box)) == box)
    }

    @Test func mergePutsWhatWasLeftBeforeWhatCameSince() {
        let id = UUID(), other = UUID()
        var left = HubOutbox()
        left.observe([a])
        left.observe([b])
        left.edit(id, text: "旧")
        left.edit(other, text: "别的")
        left.forget("x")
        var since = HubOutbox()
        since.edit(id, text: "新")
        since.forget("金币")
        since.merge(earlier: left)
        #expect(since.observations == [LearningObservations(pairs: [a])])
        #expect(since.edits == [HubOutbox.Edit(id: other, text: "别的"), HubOutbox.Edit(id: id, text: "新")])
        #expect(since.forgotten == ["x", "金币"])
    }

    @Test func unlearningTakesBackWhatWaitsElseSendsTheReverseTheHubHas() {
        let id = UUID()
        var box = HubOutbox()
        box.observe([a, b], dictationID: id)
        // Still waiting: taken back (matched as the learning book matches), nothing goes.
        box.unlearn(CorrectionPair(wrong: "open  air", right: "openai"), hubHas: true)
        #expect(box.observations == [LearningObservations(pairs: [b], dictationID: id)])
        box.unlearn(b, hubHas: false)
        #expect(box.isEmpty)
        // Gone already and the hub has it: the reverse, from the same dictation.
        box.unlearn(a, dictationID: id, hubHas: true)
        #expect(box.observations == [LearningObservations(pairs: [CorrectionPair(wrong: "OpenAI", right: "Open Air")],
                                                          dictationID: id)])
        // The hub does not have it: the reverse would be learned there as a new correction.
        box.unlearn(b, hubHas: false)
        #expect(box.observations.count == 1)
    }

    private func hubEntries(_ book: LearningBook) -> [LearningEntry] {
        book.items.map { LearningEntry(wrong: $0.pair.wrong, right: $0.pair.right, count: $0.count, lastSeen: $0.lastSeen) }
    }

    /// What the hub does with an observation (`LearningBook.record`, as neoless-hub learns).
    private func deliver(_ box: HubOutbox, to book: inout LearningBook) {
        for observation in box.observations {
            _ = book.record(observation.pairs, source: .otherApp, recordID: observation.dictationID) { _ in false }
        }
    }

    @Test func changedBackHereIsCountedDownOnTheHub() {
        // Fixed once on another day, sent, so both books count it once.
        var mac = LearningBook(), neo = LearningBook()
        _ = mac.record([a], source: .otherApp, recordID: UUID()) { _ in false }
        _ = neo.record([a], source: .otherApp, recordID: nil) { _ in false }
        // The user changes it back in another app: gone here.
        let event = mac.record([CorrectionPair(wrong: "OpenAI", right: "Open Air")], source: .otherApp, recordID: UUID()) { _ in false }
        #expect(mac.items.isEmpty && event.learned.isEmpty && event.reversed == [a])
        var box = HubOutbox()
        for pair in event.reversed { box.unlearn(pair, hubHas: HubLearning.contains(hubEntries(neo), pair)) }
        deliver(box, to: &neo)
        // Gone there too: the next sync does not bring it back.
        #expect(neo.items.isEmpty)
        #expect(HubLearning.merged(mac, hub: hubEntries(neo)).items.isEmpty)
    }

    @Test func aChainedFixLeavesTheHubWithTheComposedPairOnly() {
        // A→B learned and sent; then B→C in the same text, which this device learns as A→C instead.
        let ab = CorrectionPair(wrong: "克劳德", right: "Cloud"), ac = CorrectionPair(wrong: "克劳德", right: "Claude")
        var neo = LearningBook()
        _ = neo.record([ab], source: .otherApp, recordID: nil) { _ in false }
        var box = HubOutbox()
        box.unlearn(ab, hubHas: HubLearning.contains(hubEntries(neo), ab))
        box.observe([ac])
        deliver(box, to: &neo)
        #expect(neo.items.map(\.pair) == [ac])
        #expect(neo.items[0].count == 1)
    }

    @Test func keepsAtMostTheLimitNewestFirst() {
        var box = HubOutbox()
        for n in 0..<(HubOutbox.limit + 10) { box.observe([CorrectionPair(wrong: "w\(n)", right: "r\(n)")]) }
        #expect(box.observations.count == HubOutbox.limit)
        #expect(box.observations.first?.pairs.first?.wrong == "w10")
        // 清空 forgets every correction a device has (up to `LearningBook.maxItems`): none is dropped, and past the
        // limit the newest stay, which are the ones the Neo is likeliest to have.
        for n in 0..<LearningBook.maxItems { box.forget("f\(n)") }
        #expect(box.forgotten.count == LearningBook.maxItems)
        for n in 0..<(HubOutbox.forgetLimit + 100) { box.forget("g\(n)") }
        #expect(box.forgotten.count == HubOutbox.forgetLimit)
        #expect(box.forgotten.first == "g100" && box.forgotten.last == "g\(HubOutbox.forgetLimit + 99)")
    }

    @Test func forgettingMatchesAsTheHubForgets() {
        // The hub forgets ignoring case and spacing: a waiting pair that differs only in that would teach it again.
        var box = HubOutbox()
        box.observe([CorrectionPair(wrong: "openai", right: "OpenAI 公司"), b])
        box.forget("OpenAI")
        #expect(box.observations == [LearningObservations(pairs: [b])])
        box.forget("Open  Air")
        box.forget("open air")
        #expect(box.forgotten == ["OpenAI", "open air"])

        var since = HubOutbox()
        since.forget("金币")
        var left = HubOutbox()
        left.forget("OPENAI")
        left.observe([CorrectionPair(wrong: "金币", right: "硬币")])
        since.merge(earlier: left)
        #expect(since.forgotten == ["OPENAI", "金币"] && since.observations.isEmpty)
    }

    @Test func anEditCanBeTakenOutAndPutBack() {
        let id = UUID(), other = UUID()
        var box = HubOutbox()
        box.edit(id, text: "改过", learn: false)
        box.edit(other, text: "别的")
        let taken = box.takeEdit(id)
        #expect(taken == HubOutbox.Edit(id: id, text: "改过", learn: false))
        #expect(box.edits == [HubOutbox.Edit(id: other, text: "别的")])
        #expect(box.takeEdit(id) == nil)
    }
}

/// Collects what a flush's progress reports.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ value: Int) { lock.withLock { values.append(value) } }
    var all: [Int] { lock.withLock { values } }
}

private func respond<T: Encodable>(_ value: T, status: Int = 200) -> StubProtocol.Reply {
    .respond(status: status, headers: ["Content-Type": "application/json"], body: json(value))
}

/// The client against a stubbed hub: the dictionary's 409 and the outbox.
@Suite struct HubFlushTests {
    /// For the hub that never answers, where waiting the connection out is the test.
    private let fast = HubTimeouts(connect: 0.3, quick: 1, ping: 0.3, hubPolishFloor: 1)
    /// Room for a busy machine, as in `HubObservationTests`: everywhere else the answer comes at once, so a long
    /// wait for the connection costs nothing, while a short one can run out before the request is even sent when
    /// the suites run together (a refusal or a lost answer then read as a hub that was not reached).
    private let roomy = HubTimeouts(connect: 5, quick: 10, ping: 5, hubPolishFloor: 1)

    private func client(_ host: String, timeouts: HubTimeouts? = nil) -> HubClient {
        HubClient(server: URL(string: "https://\(host)")!, token: token, session: StubProtocol.session(),
                  timeouts: timeouts ?? roomy)
    }

    @Test func dictionaryConflictIsReadAgainAndApplied() async throws {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        let conflict = HubErrorBody(error: "词典已在别的设备上改过", code: HubErrorCode.conflict)
        StubProtocol.register(host: host) { request, body, n in
            switch n {
            case 0: return respond(VocabularySnapshot(words: ["OpenAI"], revision: "r1"))
            case 1: return respond(conflict, status: 409)
            // Meanwhile the iPhone added Martin.
            case 2: return respond(VocabularySnapshot(words: ["Martin", "OpenAI"], revision: "r2"))
            default:
                let update = try! HubJSON.decode(VocabularyUpdate.self, from: body)
                return respond(VocabularySnapshot(words: update.words, revision: "r3"))
            }
        }
        let result = try await client(host).applyVocabulary([.add(["Claude"])])
        #expect(result.words == ["Claude", "Martin", "OpenAI"] && result.revision == "r3")
        let seen = StubProtocol.requests(host: host)
        #expect(seen.map { $0.request.httpMethod ?? "" } == ["GET", "PUT", "GET", "PUT"])
        try #require(seen.count == 4)
        let first = try HubJSON.decode(VocabularyUpdate.self, from: seen[1].body)
        #expect(first == VocabularyUpdate(words: ["Claude", "OpenAI"], expectedRevision: "r1"))
        let second = try HubJSON.decode(VocabularyUpdate.self, from: seen[3].body)
        #expect(second.expectedRevision == "r2")
    }

    @Test func dictionaryThatAlreadyHasTheChangeIsNotWritten() async throws {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, _, _ in respond(VocabularySnapshot(words: ["Claude", "OpenAI"], revision: "r1")) }
        let result = try await client(host).applyVocabulary([.add(["Claude"])])
        #expect(result.revision == "r1")
        #expect(StubProtocol.requests(host: host).count == 1)
    }

    @Test func flushSendsEverythingInOrderAndDropsWhatTheHubTurnsDown() async throws {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        let gone = UUID(), kept = UUID()
        let list = LearningList(pairs: [LearningEntry(wrong: "a", right: "b", count: 1, lastSeen: Date(timeIntervalSince1970: 0))])
        StubProtocol.register(host: host) { request, body, _ in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("POST", HubPath.learningForget): return respond(list)
            case ("POST", HubPath.learningObservations): return respond(LearningObservationsResponse(accepted: 1))
            case ("POST", HubPath.edit(gone)):
                return respond(HubErrorBody(error: "Neo 上没有这条记录", code: HubErrorCode.notFound), status: 404)
            case ("POST", HubPath.edit(kept)):
                return respond(EditResponse(result: DictationResult(id: kept, clientRecordingID: kept, raw: "r", text: "t",
                                                                    mode: .natural, polished: true, recognizer: .qwen3ASR)))
            default: return .fail(.badURL)
            }
        }
        var box = HubOutbox()
        box.forget("a")
        box.forget("金币")
        box.observe([CorrectionPair(wrong: "Cloud", right: "Claude")])
        box.edit(gone, text: "改过")
        box.edit(kept, text: "改过", learn: false)
        let result = await client(host).flush(box)
        #expect(result.left.isEmpty)
        #expect(result.stoppedBy == nil)
        #expect(result.learning == list)
        #expect(result.sent == 4)
        let seen = StubProtocol.requests(host: host)
        let order = seen.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" }
        #expect(order == ["POST /v1/learning/forget", "POST /v1/learning/observations",
                          "POST \(HubPath.edit(gone))", "POST \(HubPath.edit(kept))"])
        try #require(seen.count == 4)
        // Forgotten corrections go many to a request.
        #expect(try HubJSON.decode(LearningForget.self, from: seen[0].body) == LearningForget(wrongs: ["a", "金币"]))
        // An edit whose learning this device sends itself carries the text only.
        #expect(try HubJSON.decode(EditRequest.self, from: seen[2].body) == EditRequest(text: "改过"))
        #expect(try HubJSON.decode(EditRequest.self, from: seen[3].body) == EditRequest(text: "改过", learn: false))
    }

    @Test func clearingManyCorrectionsTakesFewRequests() async throws {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, _, _ in respond(LearningList()) }
        var box = HubOutbox()
        for n in 0..<450 { box.forget("w\(n)") }
        let result = await client(host).flush(box)
        #expect(result.left.isEmpty && result.sent == 3)
        let sizes = try StubProtocol.requests(host: host).map { try HubJSON.decode(LearningForget.self, from: $0.body).wrongs.count }
        #expect(sizes == [200, 200, 50])
    }

    @Test func aFlushSendsAtMostItsRequestsAndSaysWhatIsLeftAsItGoes() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, _, _ in respond(LearningObservationsResponse(accepted: 1)) }
        var box = HubOutbox()
        for n in 0..<3 { box.observe([CorrectionPair(wrong: "Cloud\(n)", right: "Claude\(n)")]) }
        let seen = Collected()
        let result = await client(host).flush(box, requests: 2) { left in seen.add(left.observations.count) }
        // Out of requests is not a failure: the rest waits for the next minute.
        #expect(result.sent == 2 && result.stoppedBy == nil)
        #expect(result.left.observations.map { $0.pairs[0].wrong } == ["Cloud2"])
        #expect(seen.all == [2, 1])
        #expect(StubProtocol.requests(host: host).count == 2)
    }

    @Test func anItemTheHubKeepsFailingOnIsDroppedNotRetriedForever() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        let broken = UUID(), fine = UUID()
        StubProtocol.register(host: host) { request, _, _ in
            if request.url?.path == HubPath.edit(broken) {
                return respond(HubErrorBody(error: "Neo 出错了，稍后再试", code: HubErrorCode.internalError, retryable: true), status: 500)
            }
            return respond(EditResponse(result: DictationResult(id: fine, clientRecordingID: fine, raw: "r", text: "t",
                                                                mode: .natural, polished: true, recognizer: .qwen3ASR)))
        }
        var box = HubOutbox()
        box.edit(broken, text: "一")
        box.edit(fine, text: "二")
        let result = await client(host).flush(box)
        // The hub's own 500 would be the same next time: dropped, and what follows still goes.
        #expect(result.left.isEmpty && result.stoppedBy == nil)
        #expect(StubProtocol.requests(host: host).count == 2)
    }

    @Test func whatStopsAFlush() {
        // Not reached, refused, or asked to slow down: the item waits.
        for error: Error in [HubError.unreachable, HubError.offline, HubError.timeout, HubError.connectionLost,
                             HubError.server(status: 530, body: nil), HubError.server(status: 403, body: nil),
                             hubBody(429, HubErrorCode.rateLimited, retryable: true),
                             hubBody(503, HubErrorCode.asrUnavailable, retryable: true),
                             hubBody(401, HubErrorCode.unauthorized), CancellationError()] {
            #expect(HubClient.flushStops(at: error), "\(error)")
        }
        // The hub's own answer about this item: dropped.
        for error: Error in [hubBody(404, HubErrorCode.notFound), hubBody(500, HubErrorCode.internalError, retryable: true),
                             hubBody(400, HubErrorCode.badRequest), hubBody(413, HubErrorCode.tooLarge), HubError.badResponse] {
            #expect(!HubClient.flushStops(at: error), "\(error)")
        }
    }

    @Test func flushStopsWhenTheNeoCannotBeReachedAndKeepsTheRest() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, _, _ in .hang }
        var box = HubOutbox()
        box.forget("a")
        box.observe([CorrectionPair(wrong: "Cloud", right: "Claude")])
        let result = await client(host, timeouts: fast).flush(box)
        #expect(result.left == box)
        #expect(result.stoppedBy as? HubError == .unreachable)
    }

    @Test func aLearnedPairWhoseAnswerWasLostIsNotSentAgain() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { request, _, _ in
            request.url?.path == HubPath.learningObservations ? .fail(.networkConnectionLost) : .fail(.badURL)
        }
        var box = HubOutbox()
        box.observe([CorrectionPair(wrong: "Cloud", right: "Claude")])
        box.edit(UUID(), text: "改过")
        let result = await client(host).flush(box)
        // It may have arrived: not sent twice. The edit after it waits (the connection is shaky).
        #expect(result.left.observations.isEmpty)
        #expect(result.left.edits.count == 1)
        #expect(result.stoppedBy as? HubError == .connectionLost)
    }

    @Test func tooManyRequestsWaitsForTheNextFlush() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, _, _ in
            respond(HubErrorBody(error: "请求太频繁", code: HubErrorCode.rateLimited, retryable: false), status: 429)
        }
        var box = HubOutbox()
        (0..<3).forEach { box.forget("w\($0)") }
        let result = await client(host).flush(box)
        #expect(result.left == box)
        #expect(StubProtocol.requests(host: host).count == 1)
    }

    @Test func aRefusedDeviceStopsTheFlush() async {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        StubProtocol.register(host: host) { _, _, _ in
            respond(HubErrorBody(error: "设备已吊销", code: HubErrorCode.forbidden), status: 403)
        }
        var box = HubOutbox()
        box.forget("a")
        let result = await client(host).flush(box)
        #expect(result.left == box)
        #expect((result.stoppedBy as? HubError)?.needsPairing == true)
    }
}

/// The Mac's whole dictation exchange against a stubbed hub: the recording as AAC, the header, and the hub that
/// heard nothing getting this Mac's transcript under the same recording id.
@Suite struct HubDictationExchangeTests {
    @Test func recordingThenLocalTranscriptUnderOneID() async throws {
        let host = stubHost()
        defer { StubProtocol.remove(host: host) }
        let samples: [Float] = (0..<32_000).map { i in 0.3 * sin(Float(i) * 2 * .pi * 220 / 16_000) }
        let audio = AudioUpload.encode(samples)
        let request = DictationRequest(mode: .natural, autoStructured: true, appName: "微信", bundleID: "com.tencent.xinWeChat",
                                       localTranscript: nil, durationSeconds: audio.durationSeconds, client: .mac,
                                       clientVersion: "1.2.0")
        StubProtocol.register(host: host) { request, body, _ in
            switch request.url?.path {
            case HubPath.ping: return .respond(status: 200, body: Data(#"{"ok":true}"#.utf8))
            case HubPath.dictations:
                let header = try? DictationRequest(headerValue: request.value(forHTTPHeaderField: HubHeader.request) ?? "")
                let id = header?.clientRecordingID ?? UUID()
                // The hub heard nothing in it.
                return respond(DictationResult(clientRecordingID: id, raw: "", text: "", mode: .natural, polished: false,
                                               recognizer: .qwen3ASR))
            case HubPath.polish:
                let polish = try! HubJSON.decode(PolishRequest.self, from: body)
                return respond(DictationResult(clientRecordingID: polish.clientRecordingID, raw: polish.text, text: polish.text + "。",
                                               mode: .natural, polished: true, recognizer: .local))
            default: return .fail(.badURL)
            }
        }
        let client = HubClient(server: URL(string: "https://\(host)")!, token: token, session: StubProtocol.session(),
                               timeouts: .interactive)
        let first = try await client.dictate(audio, request: request)
        guard case .polish(let polish) = HubDictation.next(first, request: request, localTranscript: "明天开会") else {
            Issue.record("expected the local transcript to be polished")
            return
        }
        let result = try await client.polish(polish)
        #expect(result.text == "明天开会。" && result.recognizer == .local)
        #expect(result.clientRecordingID == request.clientRecordingID)

        let seen = StubProtocol.requests(host: host).filter { $0.request.url?.path == HubPath.dictations }
        let upload = try #require(seen.first)
        #expect(audio.type == .m4a)
        #expect(upload.request.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
        // The hub can read it back: two seconds of 16 kHz audio.
        let decoded = try AudioDecoding.samples(from: upload.body, type: .m4a)
        #expect(abs(decoded.count - samples.count) < 2_048)
        let header = try DictationRequest(headerValue: upload.request.value(forHTTPHeaderField: HubHeader.request) ?? "")
        #expect(header.bundleID == "com.tencent.xinWeChat" && header.client == .mac && header.durationSeconds == 2)
    }
}

/// What a record keeps of the Neo's answer: all four of its timings, not only the polish.
@Suite struct HubTimingsKeptTests {
    @Test func everyPartOfTheNeosWorkIsKept() {
        let hub = HubTimings(decodeMs: 25, asrMs: 3_100, polishMs: 2_400, totalMs: 5_540)
        let kept = DictationTimings(hub, requestMs: 5_900)
        #expect(kept == DictationTimings(waitMs: nil, requestMs: 5_900, decodeMs: 25, asrMs: 3_100, polishMs: 2_400,
                                         totalMs: 5_540))
        // The wait is the device's to add once the text is typed.
        #expect(kept.waitMs == nil)
        #expect(DictationTimings(HubTimings(), requestMs: nil) == DictationTimings(decodeMs: 0, asrMs: 0, polishMs: 0, totalMs: 0))
        // A call before it whose answer was not used (the Neo heard nothing, and this device's transcript followed).
        #expect(DictationTimings(hub, requestMs: 2_700, neoWaitMs: 3_500).neoWaitMs == 3_500)
        #expect(kept.neoWaitMs == nil)
    }
}
