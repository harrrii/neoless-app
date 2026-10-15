import Foundation

/// A fixed set of transcripts for `neoless --polish-eval`: the six examples of the 自然整理 instructions with
/// their expected output, then everyday dictations (chat, work messages, requests to an AI), each with a few
/// simple checks. All are made up. The set never changes between runs, so two runs (two prompt versions, two
/// models) can be compared side by side.
/// The checks are written for 自然整理; under 结构化 the ones about layout are skipped (`Check.naturalOnly`).
public enum PolishEval {
    public struct Case: Sendable, Equatable {
        public let title: String
        /// The app the dictation goes to, as the polish request names it.
        public let appName: String?
        public let transcript: String
        /// The expected 自然整理 output, for an example of the instructions.
        public let expected: String?
        /// Learned-only terms and learned pairs this case sends on top of the Mac's own, as if learning had
        /// picked them up: they check how the prompt weighs what was learned (`words(adding:)`, `corrections(adding:)`).
        public let learned: [String]
        public let corrections: [CorrectionPair]
        public let checks: [Check]

        public init(_ title: String, app: String?, _ transcript: String, expected: String? = nil,
                    learned: [String] = [], corrections: [CorrectionPair] = [], checks: [Check]) {
            self.title = title; self.appName = app; self.transcript = transcript
            self.expected = expected; self.learned = learned; self.corrections = corrections; self.checks = checks
        }

        /// The word lists for this case's request: `words` (the Mac's), with the case's learned terms first
        /// among the learned ones. A term the case lists as learned is not also listed as the user's own.
        public func words(adding words: Vocabulary.PromptWords) -> Vocabulary.PromptWords {
            guard !learned.isEmpty else { return words }
            let keys = Set(learned.map { $0.lowercased() })
            return Vocabulary.PromptWords(own: words.own.filter { !keys.contains($0.lowercased()) },
                                          learned: learned + words.learned.filter { !keys.contains($0.lowercased()) })
        }

        /// The case's pairs, then the `stored` ones for other wrong forms (one pair per wrong form, as in
        /// `LearningPrompt.pairs(for:from:)`).
        public func corrections(adding stored: [CorrectionPair]) -> [CorrectionPair] {
            let wrongs = Set(corrections.map { LearningPrompt.normalize($0.wrong) })
            return corrections + stored.filter { !wrongs.contains(LearningPrompt.normalize($0.wrong)) }
        }

        /// What is wrong with `output`, polished in `mode`, in plain Chinese; empty when every check passes.
        /// Under 结构化 the 自然整理 layout checks are left out: its own rules lay the text out differently.
        public func problems(in output: String, mode: DictationMode = .natural) -> [String] {
            checks.filter { mode != .structured || !$0.naturalOnly }
                .compactMap { $0.problem(in: output, transcript: transcript) }
        }
    }

    /// Rough, mechanical checks: a pass does not prove the result is good, a failure is worth a look.
    public enum Check: Sendable, Equatable {
        /// At least one of these must appear.
        case containsAny([String])
        /// None of these may appear.
        case lacks([String])
        /// No line break: a short message must stay one line.
        case oneLine
        /// A numbered list ("1." at the start of a line).
        case numbered
        /// No numbering: no "1." at the start of a line, and no "1." … "2." inside one.
        case notNumbered
        /// At least one blank line between paragraphs.
        case paragraphs
        /// At most this many times as long as the transcript; an answer or an essay would be longer.
        case maxLengthRatio(Double)
        /// No Chinese characters: English stays English.
        case noChinese

        /// Layout that only the 自然整理 rules ask for. The 结构化 rules write a goal sentence, then a
        /// numbered list with no blank line, and number three or more items even in a short message, so
        /// these would flag correct 结构化 output. `.oneLine` applies to both: both keep a short message
        /// with one or two points as one paragraph.
        public var naturalOnly: Bool {
            switch self {
            case .numbered, .notNumbered, .paragraphs: return true
            case .containsAny, .lacks, .oneLine, .maxLengthRatio, .noChinese: return false
            }
        }

        /// Nil when `output` passes.
        public func problem(in output: String, transcript: String) -> String? {
            switch self {
            case .containsAny(let options):
                return options.contains { output.contains($0) } ? nil
                    : "缺少" + options.map { "「\($0)」" }.joined(separator: "或")
            case .lacks(let words):
                let found = words.filter { output.contains($0) }
                return found.isEmpty ? nil : "不该出现" + found.map { "「\($0)」" }.joined(separator: "、")
            case .oneLine:
                return output.contains("\n") ? "应该只有一行" : nil
            case .numbered:
                return PolishEval.startsNumberedLine(output) ? nil : "没有编号列表"
            case .notNumbered:
                let inline = PolishEval.numberMarks.contains { output.contains("1" + $0) && output.contains("2" + $0) }
                return PolishEval.startsNumberedLine(output) || inline ? "不该编号" : nil
            case .paragraphs:
                return output.contains("\n\n") ? nil : "没有分段"
            case .maxLengthRatio(let ratio):
                let limit = Int((Double(transcript.count) * ratio).rounded(.up))
                return output.count <= limit ? nil : "比原话长太多（\(output.count) 字，原话 \(transcript.count) 字），可能在回答或扩写"
            case .noChinese:
                return output.unicodeScalars.contains(where: PolishEval.isHan) ? "出现了中文，不该翻译" : nil
            }
        }
    }

    /// `output` is the expected text, ignoring spaces, line breaks and the colon's width.
    public static func matchesExpected(_ output: String, _ expected: String) -> Bool {
        func key(_ s: String) -> String {
            String(s.replacingOccurrences(of: ":", with: "：").filter { !$0.isWhitespace })
        }
        return key(output) == key(expected)
    }

    /// What follows the number of a list item: "1." "1．" "1、".
    static let numberMarks = [".", "．", "、"]

    /// Some line, indent aside, starts with a first list item.
    static func startsNumberedLine(_ output: String) -> Bool {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { line in numberMarks.contains { line.hasPrefix("1" + $0) } }
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    public static var all: [Case] { promptExamples + everyday }

    /// The six examples of the 自然整理 instructions (`PolishPrompt.naturalExamples`), each with the app it would
    /// be dictated into and a few checks. They are part of the instructions, so these mostly show whether the
    /// model follows its own examples.
    public static let promptExamples: [Case] = zip(PolishPrompt.naturalExamples, exampleChecks).enumerated().map { n, pair in
        Case("示例 \(n + 1)：\(pair.0.title)", app: pair.1.app, pair.0.transcript, expected: pair.0.output, checks: pair.1.checks)
    }

    /// The app and the checks for each of `PolishPrompt.naturalExamples`, in the same order.
    static let exampleChecks: [(app: String, checks: [Check])] = [
        ("Codex", [.numbered, .paragraphs, .containsAny(["设置页"]), .containsAny(["测试"]), .lacks(["如下"])]),
        ("Claude", [.numbered, .paragraphs, .containsAny(["Mac 版"]), .containsAny(["iPhone 版"]), .containsAny(["震动反馈"])]),
        ("Claude", [.numbered, .containsAny(["预算"]), .containsAny(["跟进"])]),
        ("ChatGPT", [.paragraphs, .notNumbered, .containsAny(["第三节"]), .containsAny(["别直接给结论"]),
                     .containsAny(["5 点", "5:00", "17:00"]), .lacks(["延迟双删", "正确的做法"])]),
        ("Claude", [.numbered, .paragraphs, .containsAny(["2 点", "14:00"]), .containsAny(["10 点", "10:00"]), .containsAny(["回滚"])]),
        ("微信", [.oneLine, .notNumbered, .containsAny(["拿铁"]), .containsAny(["……", "…"]), .maxLengthRatio(1.5)]),
    ]

    /// Everyday dictations, with the light punctuation Apple's recognizer adds.
    public static let everyday: [Case] = [
        Case("微信闲聊：约时间", app: "微信",
             "哈哈好的没问题，那我们周四下午两点在咖啡店见吧，你到了跟我说一声",
             checks: [.oneLine, .containsAny(["周四下午两点", "周四下午 2 点"]), .containsAny(["咖啡店"]), .maxLengthRatio(1.5)]),
        Case("微信闲聊：在路上（三件事也不要编号）", app: "微信",
             "嗯我刚出门现在在地铁上，大概二十分钟到，你们先点菜吧不用等我，哦对了帮我点一个那个番茄牛腩饭",
             checks: [.notNumbered, .lacks(["嗯", "那个番茄"]), .containsAny(["二十分钟", "20 分钟"]), .containsAny(["番茄牛腩饭"]),
                      .maxLengthRatio(1.5)]),
        Case("工作消息：中英混说", app: "Slack",
             "跟 Martin 说一下那个 Open Air 的 API key 我已经换好了，然后 Codex 那边的 rate limit 还是有点问题，我明天上午再看一下，另外下周一的 demo 先不要跟客户确认时间",
             checks: [.containsAny(["Martin"]), .containsAny(["OpenAI"]), .lacks(["Open Air"]), .containsAny(["API key"]),
                      .containsAny(["Codex"]), .containsAny(["rate limit"]), .containsAny(["下周一"]), .containsAny(["不要"])]),
        Case("对 Codex 说的请求（只整理，不回答）", app: "Codex",
             "帮我看一下这个登录页面为什么点了按钮之后没反应，然后顺便把那个 loading 的状态也加上，但是不要动 API 那部分的代码，改完跑一下测试",
             checks: [.containsAny(["登录"]), .containsAny(["loading"]), .containsAny(["不要"]), .containsAny(["API"]),
                      .containsAny(["测试"]), .lacks(["可能是", "原因是", "你可以"]), .maxLengthRatio(1.6)]),
        Case("中途改口：两百，不对，一百八", app: "微信",
             "昨天那顿火锅一共两百，不对，一百八，咱俩 AA 你转我九十就行，不着急",
             checks: [.containsAny(["一百八", "180"]), .lacks(["两百", "200"]), .containsAny(["九十", "90"]), .notNumbered,
                      .maxLengthRatio(1.5)]),
        Case("口述的问题（不能回答）", app: "微信",
             "你觉得十月份去海边的话那边的民宿要提前多久订啊",
             checks: [.containsAny(["民宿"]), .containsAny(["？", "?"]), .lacks(["建议", "通常", "提前一个月"]),
                      .oneLine, .maxLengthRatio(1.5)]),
        Case("对 AI 的指令（不能执行）", app: "ChatGPT",
             "帮我写一封邮件给房东说我下周三的看房去不了因为那天要出差",
             checks: [.containsAny(["房东"]), .containsAny(["下周三"]), .containsAny(["出差"]),
                      .lacks(["尊敬", "您好", "此致", "Dear"]), .maxLengthRatio(1.6)]),
        Case("给客户的长消息（多个话题）", app: "微信",
             "王女士您好，今天把厨房的水龙头换好了，整体没什么问题，就是水槽下面的软管有点老化，然后这几天麻烦您做三件事，水龙头先别开到最大，晚上看一下柜子里有没有渗水，旧的软管先别扔，对了下周二的上门检查要改到周三晚上七点，因为我那天排满了，麻烦您看一下可不可以",
             checks: [.numbered, .paragraphs, .containsAny(["软管"]), .containsAny(["渗水"]), .containsAny(["别扔"]),
                      .containsAny(["周三晚上七点", "周三晚上 7 点", "周三晚上 7:00"]), .containsAny(["排满"])]),
        Case("一句话（必须保持一行）", app: "微信",
             "好的收到我晚点回你",
             checks: [.oneLine, .notNumbered, .containsAny(["晚点回你"]), .maxLengthRatio(2)]),
        Case("英文消息（不翻译）", app: "Slack",
             "can you send me the slides before tomorrow's meeting thanks",
             checks: [.oneLine, .noChinese, .containsAny(["slides"]), .maxLengthRatio(1.4)]),
        // Learning took one edit of VIP to ZIP (a zip file) and added ZIP as a learned term. Here VIP means
        // a member: what learning picked up is used only when the context fits, so VIP stays.
        Case("只学过一次的词不硬套：VIP 会员", app: "微信",
             "把那个 VIP 客户名单整理一下，下周给他们发会员续费的通知",
             learned: ["ZIP"], corrections: [CorrectionPair(wrong: "VIP", right: "ZIP")],
             checks: [.containsAny(["VIP"]), .lacks(["ZIP"]), .containsAny(["会员续费"])]),
    ]
}
