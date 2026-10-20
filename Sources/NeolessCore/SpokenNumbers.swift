import Foundation

/// Numbers said in Chinese that can be written in digits without knowing what the sentence is about, so a
/// short dictation (`QuickTidy`) gets them without asking ChatGPT:
/// - a string of digits read one by one, three or more ("一三五七九二", a phone number, an account, a code):
///   135792;
/// - spoken arithmetic ("五乘五", "十二除以四等于三"): 5*5, 12/4=3, the way the polish rules write it
///   (`PolishPrompt.termRules`). The recognizer often puts a comma where the speaker paused ("五乘五，加五六七八"):
///   it is part of the sum, which is written without it (5*5+5678). Nothing is worked out: only what was said
///   is written.
///
/// Any other number ("七十二", "三百块", "两点") is left as said: whether it is a quantity, kept in words, or a
/// price or a time, written in digits, depends on the sentence. `needsModel(_:)` tells such a sentence apart.
public enum SpokenNumbers {
    /// `text` with the digit strings and the arithmetic written in digits.
    public static func written(_ text: String) -> String {
        var out = replace(arithmetic, in: text) { match, s in
            var expression = ""
            for piece in tokens(s(match.range)) {
                switch piece {
                case .number(let words): guard let n = number(words) else { return nil }; expression += n
                case .op(let word): expression += operators[word]!
                }
            }
            return expression
        }
        out = replace(digitRun, in: out) { match, s in
            let run = s(match.range)
            // 七七八八, 一一二二: an idiom, not a number.
            let c = Array(run)
            if c.count == 4, c[0] == c[1], c[2] == c[3] { return nil }
            return String(run.map { Character(String(digits[$0]!)) })
        }
        return out
    }

    /// Whether `text` holds a number in words that only the model can write well: one with 十, 百, 千, 万 or 亿
    /// ("七十二", "三百"), or a time ("三点"). 一 on its own ("一下", "一点", "一起") is not one.
    public static func needsModel(_ text: String) -> Bool {
        positional.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Reading

    static let digits: [Character: Int] = ["零": 0, "〇": 0, "幺": 1, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                           "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    static let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    static let operators = ["乘以": "*", "乘": "*", "加上": "+", "加": "+", "减去": "-", "减": "-", "除以": "/", "等于": "="]

    /// The number `words` says, in digits: "二十五" 25, "一百零五" 105, "一百二" 120, "两万三" 23000,
    /// "三点五" 3.5, "二五" 25 (digits one by one). Nil when it is not a number.
    static func number(_ words: String) -> String? {
        let parts = words.split(separator: "点", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = integer(String(parts[0])) else { return nil }
        guard parts.count == 2 else { return whole }
        let fraction = parts[1].compactMap { digits[$0] }
        guard !parts[1].isEmpty, fraction.count == parts[1].count else { return nil }
        return whole + "." + fraction.map(String.init).joined()
    }

    private static func integer(_ words: String) -> String? {
        guard !words.isEmpty else { return nil }
        // Read one by one: "二五", "三零".
        if words.allSatisfy({ digits[$0] != nil }) {
            return words.map { String(digits[$0]!) }.joined()
        }
        return value(Substring(words)).map(String.init)
    }

    /// "三亿五千万" = 三 × 亿 + 五千万; "两万三" = 2 × 万 + 3 × 千 (a lone digit after the unit counts in the
    /// unit below it). Below 万: `section`.
    private static func value(_ words: Substring) -> Int? {
        for (mark, size) in [("亿" as Character, 100_000_000), ("万", 10_000)] {
            guard let i = words.firstIndex(of: mark) else { continue }
            guard let high = value(words[..<i]), high > 0 else { return nil }
            var low = words[words.index(after: i)...]
            if low.isEmpty { return high * size }
            if low.count == 1, let d = digits[low.first!], d > 0 { return high * size + d * size / 10 }
            while low.first.map({ digits[$0] == 0 }) == true { low = low.dropFirst() }
            guard let rest = value(low), rest < size else { return nil }
            return high * size + rest
        }
        return section(words)
    }

    /// A number below 万: "二十五" 25, "十五" 15, "一百零五" 105, "一百二" 120, "两千零二十六" 2026.
    private static func section(_ words: Substring) -> Int? {
        guard !words.isEmpty else { return nil }
        var total = 0, pending: Int?, lastUnit = 1, sawZero = false
        for c in words {
            if let d = digits[c] {
                if d == 0 { sawZero = true; continue }
                guard pending == nil else { return nil }
                pending = d
            } else if let unit = units[c], unit < lastUnit || lastUnit == 1 {
                total += (pending ?? 1) * unit
                pending = nil; lastUnit = unit; sawZero = false
            } else {
                return nil
            }
        }
        if let d = pending { total += (!sawZero && lastUnit >= 100) ? d * lastUnit / 10 : d }
        return total
    }

    private enum Token { case number(String), op(String) }

    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            if let word = operators.keys.sorted(by: { $0.count > $1.count }).first(where: { rest.hasPrefix($0) }) {
                out.append(.op(word)); rest = rest.dropFirst(word.count)
            } else if let c = rest.first, pauses.contains(c) {
                rest = rest.dropFirst()
            } else {
                let n = rest.prefix { numberCharacters.contains($0) }
                guard !n.isEmpty else { break }
                out.append(.number(String(n))); rest = rest.dropFirst(n.count)
            }
        }
        return out
    }

    // MARK: Patterns

    private static let numberCharacters = Set("零〇幺一二三四五六七八九两十百千万亿点")
    /// What the recognizer writes for a pause inside a sum.
    private static let pauses = Set("，,、 ")
    private static let pause = "[，,、 ]*"
    /// One number said in words, maybe with a decimal part.
    private static let operand = "[零〇幺一二三四五六七八九两十百千万亿]+(?:点[零〇一二三四五六七八九]+)?"
    private static let op = "(?:乘以|乘|加上|加|减去|减|除以|等于)"
    /// A number, then one or more "operator number". Not after a word a number is part of (第一, 统一, 唯一,
    /// 万一, 之一…), and not when a measure word follows ("二加一个按钮" adds a button, it is no sum).
    /// The edges also leave out the characters of a number, so a match never starts or stops inside one
    /// ("二加一百个" is not 2+1 followed by 百个).
    private static let arithmetic = try! NSRegularExpression(pattern:
        "(?<![第统唯万之同专单逐初再周礼星不零〇幺一二三四五六七八九两十百千点])\(operand)(?:\(pause)\(op)\(pause)\(operand))+"
        + "(?![个只次条件张位名岁天年月日号块元下些起样种份把本台部辆杯瓶碗双对零〇幺一二三四五六七八九两十百千万亿点])")
    /// Three or more digits read one by one, not part of a larger number in words.
    private static let digitRun = try! NSRegularExpression(pattern:
        "(?<![十百千万亿点零〇幺一二三四五六七八九两])[零〇幺一二三四五六七八九]{3,}(?![十百千万亿点零〇幺一二三四五六七八九两])")
    private static let positional = try! NSRegularExpression(pattern:
        "[零〇一二三四五六七八九两][十百千万亿]|十[一二三四五六七八九]|[二三四五六七八九十两]点")

    private static func replace(_ pattern: NSRegularExpression, in text: String,
                                _ with: (NSTextCheckingResult, (NSRange) -> String) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let new = with(match, { ns.substring(with: $0) }) else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + new
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}
