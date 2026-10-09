import Testing
@testable import LucaKit

@Test func utf8LengthStringsStoreTheirLengthNegated() {
    // "AB" is stored as 0x10000 - 2 = 0xFFFE, then the bytes and a NUL.
    var r = ParamReader([0xFE, 0xFF, 0x41, 0x42, 0x00, 0x07, 0x00])
    #expect(r.lstrUTF8() == "AB")
    #expect(r.u16() == 7)
}

@Test func utf16LengthStringsCountCodeUnits() {
    var r = ParamReader([0x02, 0x00, 0x41, 0x00, 0x42, 0x00, 0x00, 0x00, 0x09, 0x00])
    #expect(r.lstrUTF16() == "AB")
    #expect(r.u16() == 9)
}

@Test func expressionsReadVariablesAndOperators() {
    let vars: [Int: Int] = [12008: 0, 24006: 6, 14003: 5, 6046: 1]
    func eval(_ s: String) -> Int { LucaExpression.evaluate(s, variables: { vars[$0] ?? 0 }) }
    #expect(eval("(#12008==0)") == 1)
    #expect(eval("((#24006>=6)&&#14003!=1)") == 1)
    #expect(eval("((#14003&4)==4)") == 1)
    #expect(eval("(#24006>6||#12008)") == 0)
    #expect(eval("(#6046)") == 1)
    #expect(eval("(@get_flag(3)==0)") == 1)
}

@Test func messageMarkupBecomesPlainText() {
    let parsed = LucaPlayer.parse("@Hairi@❝I'm$[鳥白島$/とりしろじま$] ﹣ $C[ffff00]$(101)$C[]!❞", strings: [101: "Torishiro"])
    #expect(parsed.speaker == "Hairi")
    #expect(parsed.text == "\"I'm鳥白島 - Torishiro!\"")
}
