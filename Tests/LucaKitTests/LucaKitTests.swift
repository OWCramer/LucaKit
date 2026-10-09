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
