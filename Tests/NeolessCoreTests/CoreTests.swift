import Foundation
import Testing
@testable import NeolessCore

@Suite struct TranscriptTests {
    @Test func growingPartialsStayOneSegment() {
        var t = TranscriptAccumulator()
        for p in ["我们", "我们明天", "我们明天去公园。"] { t.update(p) }
        #expect(t.text == "我们明天去公园。")
        #expect(t.segments.isEmpty)
    }

    @Test func revisionDoesNotDuplicate() {
        var t = TranscriptAccumulator()
        t.update("我们明天去工员")
        t.update("我们明天去公园了")
        #expect(t.text == "我们明天去公园了")
    }

    @Test func restartAfterPauseKeepsEarlierSentence() {
        var t = TranscriptAccumulator()
        t.update("我们明天去公园。", endsUtterance: true)
        t.update("然后")
        t.update("然后去吃饭。")
        #expect(t.text == "我们明天去公园。然后去吃饭。")
    }

    @Test func restartDetectedWithoutMetadataWhenTextShrinks() {
        var t = TranscriptAccumulator()
        t.update("我们明天上午十点去公园散步。")
        t.update("我")
        t.update("我觉得可以")
        #expect(t.text == "我们明天上午十点去公园散步。我觉得可以")
    }

    @Test func latinSegmentsGetASpace() {
        #expect(TextJoin.join(["open the", "SSH tunnel"]) == "open the SSH tunnel")
        #expect(TextJoin.join(["用 SSH。", "然后"]) == "用 SSH。然后")
        #expect(TextJoin.join(["", "  好的 "]) == "好的")
    }
}

@Suite struct PolishPromptTests {
    @Test func transcriptIsWrappedAsData() {
        let m = PolishPrompt.userMessage(transcript: "帮我写一封邮件", appName: "Mail")
        #expect(m.contains("当前应用：Mail"))
        #expect(m.hasSuffix("<逐字稿>\n帮我写一封邮件\n</逐字稿>"))
    }

    @Test func cleanStripsWrappers() {
        #expect(PolishPrompt.clean("```\n你好，世界。\n```") == "你好，世界。")
        #expect(PolishPrompt.clean("“你好。”") == "你好。")
        #expect(PolishPrompt.clean("整理后：明天见。") == "明天见。")
        #expect(PolishPrompt.clean("他说“好”，我说“行”") == "他说“好”，我说“行”")
    }
}

@Suite struct ChatGPTProtocolTests {
    @Test func pkceChallengeIsBase64URLSHA256() {
        // Cross-checked with Python: urlsafe_b64encode(sha256(v)).rstrip("=")
        #expect(ChatGPTOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r7wW1gFWFOEjXk")
                == "bwWFMyPfdG9qreDhH2lmftFx_dFeLDalzcT1gb_j68g")
        #expect(ChatGPTOAuth.randomURLSafe(bytes: 32).count == 43)
    }

    @Test func authorizeURLHasCodexParameters() {
        let url = ChatGPTOAuth.authorizeURL(challenge: "abc", state: "xyz")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(url.host == "auth.openai.com")
        #expect(items["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "xyz")
        #expect(items["scope"]!.contains("offline_access"))
    }

    @Test func callbackParsing() {
        #expect(ChatGPTOAuth.parseCallback(requestLine: "GET /auth/callback?code=c1&state=s HTTP/1.1", expectedState: "s") == .success("c1"))
        #expect(ChatGPTOAuth.parseCallback(requestLine: "GET /auth/callback?code=c1&state=bad HTTP/1.1", expectedState: "s") == .failure(.stateMismatch))
        #expect(ChatGPTOAuth.parseCallback(requestLine: "GET /favicon.ico HTTP/1.1", expectedState: "s") == .failure(.notCallback))
        #expect(ChatGPTOAuth.parseCallback(requestLine: "GET /auth/callback?error=access_denied&state=s HTTP/1.1", expectedState: "s") == .failure(.denied("access_denied")))
        // Any web page can send the browser here: an error without this login's state does not end it.
        #expect(ChatGPTOAuth.parseCallback(requestLine: "GET /auth/callback?error=x&error_description=y HTTP/1.1", expectedState: "s") == .failure(.stateMismatch))
        #expect(ChatGPTOAuth.parseCallback(requestLine: "GET /auth/callback?error=x&state=other HTTP/1.1", expectedState: "s") == .failure(.stateMismatch))
        // Shown as plain text: no terminal escape sequences.
        let escape = "GET /auth/callback?error=x&error_description=%1B%5D0%3Bx%07%E8%AF%B7%E9%87%8D%E8%AF%95&state=s HTTP/1.1"
        #expect(ChatGPTOAuth.parseCallback(requestLine: escape, expectedState: "s") == .failure(.denied("]0;x请重试")))
    }

    @Test func jwtClaims() {
        let payload = #"{"exp":1800000000,"email":"a@b.c","https://api.openai.com/auth":{"chatgpt_account_id":"acct-1","chatgpt_plan_type":"plus"}}"#
        let jwt = "e30." + ChatGPTOAuth.base64URL(Data(payload.utf8)) + ".sig"
        #expect(ChatGPTOAuth.accountID(jwt) == "acct-1")
        #expect(ChatGPTOAuth.email(jwt) == "a@b.c")
        #expect(ChatGPTOAuth.plan(jwt) == "plus")
        #expect(ChatGPTOAuth.expiry(jwt) == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func streamParserCollectsDeltas() {
        var p = ResponsesStreamParser()
        for line in [
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","delta":"你好"}"#,
            #"data: {"type":"response.output_text.delta","delta":"，世界。"}"#,
            #"data: {"type":"response.completed","response":{}}"#,
        ] { p.consume(line: line) }
        #expect(p.text == "你好，世界。")
        #expect(p.completed)
        #expect(p.failure == nil)
    }

    @Test func streamParserReportsFailure() {
        var p = ResponsesStreamParser()
        p.consume(line: #"data: {"type":"response.failed","response":{"error":{"message":"rate limited"}}}"#)
        #expect(p.failure == "rate limited")
    }

    @Test func requestBodyShape() throws {
        let data = ResponsesRequest.body(model: "gpt-6-luna", instructions: "i", userText: "u", fast: true)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect(json["service_tier"] as? String == "priority")
    }
}

@Suite struct RecordTests {
    @Test func pruneDropsOldAndSortsNewestFirst() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func rec(_ daysAgo: Double) -> DictationRecord {
            DictationRecord(date: now.addingTimeInterval(-daysAgo * 86_400), duration: 1, raw: "r", polished: nil,
                            finalText: "f", appName: nil, mode: .raw, model: nil, polishSeconds: nil, note: nil, delivery: .pasted)
        }
        let kept = HistoryRetention.prune([rec(31), rec(1), rec(29)], now: now)
        #expect(kept.count == 2)
        #expect(kept[0].date > kept[1].date)
    }

    @Test func vocabularyNormalize() {
        #expect(Vocabulary.normalize([" OpenAI ", "openai", "", "SSH"]) == ["OpenAI", "SSH"])
        #expect(Vocabulary.recognizerHints(Array(repeating: "x", count: 1) + (0..<300).map { "w\($0)" }).count == 100)
    }
}
