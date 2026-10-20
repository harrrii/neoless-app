import Foundation

/// A short utterance ("好的，马上到", "帮我看一下这个报错") is tidied on the spot instead of being sent to ChatGPT:
/// a polish request costs 2.5–4 s whatever its length (the model's start-up and the long instructions), which
/// on a sentence this short is all waiting and almost no change. The recognizers already punctuate; what is left
/// is the confirmed corrections (applied by the caller, `LearningPrompt.applyConfirmed`), the habits that are a
/// plain swap ("把所有的吧换成“罢”", `swap(in:)`), digits read one by one and spoken arithmetic written in
/// digits ("四六七零" 4670, "五乘五" 5*5: `SpokenNumbers`), a leading filler word and the space between Chinese
/// and Latin text or digits. Other habits ("微信里句末不要句号") are the user's own words, which only the model can follow:
/// they are left out here, as the user chose speed for short sentences.
///
/// Anything a model is needed for keeps going to ChatGPT: a change of mind ("不对", "我是说"), numbers said
/// in words that may or may not be written in digits ("百分之" for 1.5%, "七十二", "三点": `SpokenNumbers.needsModel`),
/// more than one line. Polishing a dictation again (`repolish`) always asks ChatGPT.
public enum QuickTidy {
    /// Characters, not counting whitespace: about one short sentence, or two seconds of speech.
    public static let maxCharacters = 20

    /// Words that mean the speaker changed their mind or said a number the model would write in digits.
    static let needsModel = ["不对", "算了", "我是说", "重说", "百分之", "\n"]

    /// Whether `transcript` is short and plain enough to be tidied without ChatGPT.
    public static func applies(to transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        guard count > 0, count <= maxCharacters else { return false }
        return !needsModel.contains { text.contains($0) } && !SpokenNumbers.needsModel(SpokenNumbers.written(text))
    }

    /// `text` with the habits that are a plain swap made (`swaps(for: habits)`), digit strings and arithmetic in
    /// digits (`SpokenNumbers.written`), a leading filler word ("嗯，", "呃") and stand-alone ones between commas
    /// taken out, and a space between Chinese and Latin letters or digits (the polish rules' 中文与英文单词、数字之间
    /// 加一个半角空格).
    public static func tidy(_ text: String, habits: [String]) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for swap in swaps(for: habits) {
            out = out.replacingOccurrences(of: swap.from, with: swap.to)
        }
        out = SpokenNumbers.written(out)
        let swapped = out
        let filler = "(?:嗯|呃|额|唔|啊)+"
        out = out.replacingOccurrences(of: "^\(filler)[，,、。\\s]*", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "([，,])\\s*\(filler)\\s*[，,]", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "(\\p{Han})([A-Za-z0-9])", with: "$1 $2", options: .regularExpression)
        out = out.replacingOccurrences(of: "([A-Za-z0-9%])(\\p{Han})", with: "$1 $2", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing but fillers: keep what was said rather than type nothing.
        return out.isEmpty ? swapped : out
    }

    // MARK: Swap habits

    /// One habit that says "write this word as that word", nothing more.
    public struct Swap: Equatable, Sendable {
        public var from: String
        public var to: String
    }

    /// The swaps `habits` ask for, in their order: the habits that are a plain swap (`swap(in:)`).
    public static func swaps(for habits: [String]) -> [Swap] { habits.compactMap(swap(in:)) }

    /// The swap `habit` asks for when it is only that: "把吧换成罢", "把所有的吧换成“罢”", "“首先”都改成“第一”".
    /// It must start with 把 or with the quoted word, so a habit with a condition in front ("微信里把吧换成罢")
    /// is left to the model. Each word is one to eight characters, without spaces or quotes.
    static func swap(in habit: String) -> Swap? {
        let line = habit.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = swapPattern.firstMatch(in: line, range: range) else { return nil }
        func word(_ names: [String]) -> String? {
            for name in names {
                let r = match.range(withName: name)
                if r.location != NSNotFound, let s = Range(r, in: line) { return String(line[s]) }
            }
            return nil
        }
        guard let from = word(["fromA", "fromB", "fromC"]), let to = word(["toA", "toB"]), from != to else { return nil }
        return Swap(from: from, to: to)
    }

    /// A quote mark, and a word: one to eight characters that are not spaces, quotes or sentence marks.
    private static let open = "[“\"「『‘']", close = "[”\"」』’']", word = "[^“”\"「」『』‘’'\\s。，,！!？?]{1,8}"
    /// 把 [所有的] word | 把 [所有的] “word” | “word”, then [都] 换成 / 改成 / …, then word or “word”, then at most
    /// a full stop. The unquoted word after 把 is matched lazily, so "把吧都换成罢" swaps 吧, not 吧都.
    private static let swapPattern = try! NSRegularExpression(pattern:
        "^(?:把(?:所有的?|全部的?)?(?:\(open)(?<fromA>\(word))\(close)|(?<fromB>\(word)?))|\(open)(?<fromC>\(word))\(close))"
        + "(?:都|全)?(?:换成|改成|替换成|替换为|改为|换为|写成)"
        + "(?:\(open)(?<toA>\(word))\(close)|(?<toB>\(word)))[。！!.]?$")
}
