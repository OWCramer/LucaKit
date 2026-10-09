import Foundation

/// A Luca System script from `SCRIPT.PAK`: a run of instructions, each
/// `length: UInt16, opcode: UInt8, fixedFlag: UInt8, bytes[length - 4]`, padded to an even
/// length. A fixed flag of 1 or 2 puts that many `UInt16`s before the parameters.
/// Jumps hold byte offsets into the script. (Layout per LuckSystem, MIT.)
public struct LucaScript: Sendable {
    public struct Instruction: Sendable {
        public let index: Int
        /// Byte offset in the script: what jumps refer to.
        public let position: Int
        public let opcode: UInt8
        public let fixed: [UInt16]
        public let params: [UInt8]
    }

    public let name: String
    public let instructions: [Instruction]
    private let indexByPosition: [Int: Int]

    public init(name: String, data: Data) throws {
        self.name = name
        let d = [UInt8](data)
        var instructions: [Instruction] = []
        var byPosition: [Int: Int] = [:]
        var pos = 0
        while pos + 4 <= d.count {
            let length = Int(UInt16(d[pos]) | UInt16(d[pos + 1]) << 8)
            guard length >= 4, pos + length <= d.count else {
                if length == 0 { break } // trailing padding
                throw LucaError.badScript(name, "instruction at \(pos) has length \(length)")
            }
            let opcode = d[pos + 2]
            let flag = d[pos + 3]
            var body = Array(d[(pos + 4)..<(pos + length)])
            var fixed: [UInt16] = []
            let fixedCount = flag >= 2 ? 2 : Int(flag)
            if fixedCount > 0, body.count >= fixedCount * 2 {
                for i in 0..<fixedCount { fixed.append(UInt16(body[i * 2]) | UInt16(body[i * 2 + 1]) << 8) }
                body.removeFirst(fixedCount * 2)
            }
            byPosition[pos] = instructions.count
            instructions.append(Instruction(index: instructions.count, position: pos, opcode: opcode, fixed: fixed, params: body))
            pos += (length + 1) & ~1
        }
        self.instructions = instructions
        indexByPosition = byPosition
    }

    /// The instruction starting at byte offset `position`.
    public func index(atPosition position: Int) -> Int? { indexByPosition[position] }
}

public enum LucaError: Error, CustomStringConvertible {
    case badScript(String, String)
    case missing(String)

    public var description: String {
        switch self {
        case .badScript(let name, let why): "script \(name): \(why)"
        case .missing(let what): "missing \(what)"
        }
    }
}

/// Reads an instruction's parameters the way LuckSystem's plugin `core` does.
public struct ParamReader {
    public let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var canRead: Bool { offset < bytes.count }

    public mutating func u8() -> UInt8 {
        guard offset < bytes.count else { return 0 }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() -> UInt16 {
        guard offset + 2 <= bytes.count else { offset = bytes.count; return 0 }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public mutating func i16() -> Int16 { Int16(bitPattern: u16()) }

    public mutating func u32() -> UInt32 {
        guard offset + 4 <= bytes.count else { offset = bytes.count; return 0 }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// The rest as `UInt16`s (an odd last byte is dropped).
    public mutating func rest16() -> [UInt16] {
        var out: [UInt16] = []
        while remaining >= 2 { out.append(u16()) }
        offset = bytes.count
        return out
    }

    /// A length-prefixed UTF-8 string: the length is stored as `0x10000 - count`, then the
    /// bytes and a NUL.
    public mutating func lstrUTF8() -> String {
        let stored = Int(u16())
        if stored == 0 {
            if offset < bytes.count, bytes[offset] == 0 { offset += 1 }
            return ""
        }
        let count = 0x10000 - stored
        let end = min(offset + count, bytes.count)
        let s = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = min(end + 1, bytes.count)
        return s
    }

    /// A length-prefixed UTF-16LE string: the length in code units, then the text and a
    /// two-byte NUL.
    public mutating func lstrUTF16() -> String {
        let count = Int(u16())
        if count == 0 {
            if offset + 1 < bytes.count, bytes[offset] == 0, bytes[offset + 1] == 0 { offset += 2 }
            return ""
        }
        let end = min(offset + count * 2, bytes.count)
        let s = utf16(bytes[offset..<end])
        offset = min(end + 2, bytes.count)
        return s
    }

    /// A NUL-terminated UTF-8 string.
    public mutating func cstrUTF8() -> String {
        var end = offset
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        let s = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = min(end + 1, bytes.count)
        return s
    }

    /// A NUL-terminated UTF-16LE string.
    public mutating func cstrUTF16() -> String {
        var end = offset
        while end + 1 < bytes.count, !(bytes[end] == 0 && bytes[end + 1] == 0) { end += 2 }
        let s = utf16(bytes[offset..<min(end, bytes.count)])
        offset = min(end + 2, bytes.count)
        return s
    }

    private func utf16(_ slice: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(slice.count / 2)
        var i = slice.startIndex
        while i + 1 < slice.endIndex {
            units.append(UInt16(slice[i]) | UInt16(slice[i + 1]) << 8)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
