import Testing
@testable import NeolessCore

@Suite struct SpokenNumbersTests {
    @Test func digitsReadOneByOneAreWrittenInDigits() {
        #expect(SpokenNumbers.written("一二三四五六七八九零一二三四。") == "12345678901234。")
        #expect(SpokenNumbers.written("验证码是幺三八零") == "验证码是1380")
        #expect(SpokenNumbers.written("一二三") == "123")
        // Two digits, an idiom, or part of a number in words: left as said.
        #expect(SpokenNumbers.written("三五个人") == "三五个人")
        #expect(SpokenNumbers.written("差不多七七八八了") == "差不多七七八八了")
        #expect(SpokenNumbers.written("九九八十一") == "九九八十一")
        #expect(SpokenNumbers.written("一五一十地说") == "一五一十地说")
    }

    @Test func spokenArithmeticIsWrittenAsArithmetic() {
        #expect(SpokenNumbers.written("五乘五") == "5*5")
        #expect(SpokenNumbers.written("五乘以五等于二十五") == "5*5=25")
        #expect(SpokenNumbers.written("十二除以四等于三") == "12/4=3")
        #expect(SpokenNumbers.written("帮我算一下一百二加三十五") == "帮我算一下120+35")
        #expect(SpokenNumbers.written("三点五乘二") == "3.5*2")
        #expect(SpokenNumbers.written("两千零二十六减一九九八") == "2026-1998")
        #expect(SpokenNumbers.written("三万五千除以五") == "35000/5")
        #expect(SpokenNumbers.written("两万三减去两万零三") == "23000-20003")
        // The recognizer's comma for a pause is no break in the sum.
        #expect(SpokenNumbers.written("五乘五，加五六七八。") == "5*5+5678。")
        #expect(SpokenNumbers.written("三加四， 等于七") == "3+4=7")
    }

    @Test func wordsThatOnlyLookLikeArithmeticAreLeftAlone() {
        #expect(SpokenNumbers.written("一加手机") == "一加手机")
        #expect(SpokenNumbers.written("统一加三个按钮") == "统一加三个按钮")
        #expect(SpokenNumbers.written("选项二加一个按钮") == "选项二加一个按钮")
        #expect(SpokenNumbers.written("二加一百个") == "二加一百个")
        #expect(SpokenNumbers.written("我们去乘凉") == "我们去乘凉")
        #expect(SpokenNumbers.written("帮我看一下") == "帮我看一下")
        #expect(SpokenNumbers.written("选五，加油") == "选五，加油")
        #expect(SpokenNumbers.written("第五，加三个") == "第五，加三个")
        #expect(SpokenNumbers.written("要五，加两个") == "要五，加两个")
    }

    @Test func numbersWithUnitsAreLeftToTheModel() {
        #expect(SpokenNumbers.needsModel("一共七十二封"))
        #expect(SpokenNumbers.needsModel("三百块"))
        #expect(SpokenNumbers.needsModel("十五号见"))
        #expect(SpokenNumbers.needsModel("三点见"))
        #expect(!SpokenNumbers.needsModel("快一点"))
        #expect(!SpokenNumbers.needsModel("帮我看一下"))
        #expect(!SpokenNumbers.needsModel("十分好看"))
        #expect(!SpokenNumbers.needsModel("千万别忘了"))
        #expect(!SpokenNumbers.needsModel("万一不行呢"))
        #expect(!SpokenNumbers.needsModel("5*5=25"))
    }

    @Test func numbersInWords() {
        #expect(SpokenNumbers.number("十五") == "15")
        #expect(SpokenNumbers.number("一百零五") == "105")
        #expect(SpokenNumbers.number("三亿五千万") == "350000000")
        #expect(SpokenNumbers.number("十百") == nil)
        #expect(SpokenNumbers.number("三点") == nil)
    }
}
