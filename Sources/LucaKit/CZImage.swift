import Foundation

/// A decoded Luca System CZ image (CZ0–CZ4), as RGBA8 (straight alpha).
///
/// Formats as documented by LuckSystem (github.com/wetor/LuckSystem, MIT):
/// - header: "CZx\0", header length, width, height (`UInt16`), colour bits (`UInt16`),
///   colour block (`UInt8`); CZ0/CZ3/CZ4 follow with a flag, an x/y offset and two more
///   sizes — the offset places a sprite on its canvas.
/// - CZ0: raw RGBA. CZ1: LZW (16-bit codes), palettised 4/8-bit, RGB or RGBA. CZ2: LZW with
///   15/18-bit codes (fonts). CZ3: LZW, rows delta-coded against the row above in three
///   bands. CZ4: like CZ3 with RGB and alpha in separate planes.
public struct CZImage: Sendable {
    public let width: Int
    public let height: Int
    /// Where the image sits on its canvas (CZ0/3/4); zero otherwise.
    public let offsetX: Int
    public let offsetY: Int
    /// Canvas size the offset refers to, when the header names one.
    public let canvasWidth: Int
    public let canvasHeight: Int
    /// `width * height * 4` bytes, RGBA, straight alpha.
    public let rgba: [UInt8]

    public enum Failure: Error, CustomStringConvertible {
        case notCZ
        case unsupported(String)
        case corrupt(String)

        public var description: String {
            switch self {
            case .notCZ: "not a CZ image"
            case .unsupported(let what): "unsupported CZ image: \(what)"
            case .corrupt(let what): "corrupt CZ image: \(what)"
            }
        }
    }

    public init(width: Int, height: Int, offsetX: Int, offsetY: Int, canvasWidth: Int, canvasHeight: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.rgba = rgba
    }

    /// `part` drawn over this image ("over", straight alpha), both placed by their offsets.
    public func composited(with part: CZImage) -> CZImage {
        var out = rgba
        let dx = part.offsetX - offsetX, dy = part.offsetY - offsetY
        for py in 0..<part.height {
            let y = py + dy
            guard y >= 0, y < height else { continue }
            for px in 0..<part.width {
                let x = px + dx
                guard x >= 0, x < width else { continue }
                let s = (py * part.width + px) * 4
                let a = Int(part.rgba[s + 3])
                if a == 0 { continue }
                let d = (y * width + x) * 4
                if a == 255 {
                    out[d] = part.rgba[s]; out[d + 1] = part.rgba[s + 1]; out[d + 2] = part.rgba[s + 2]; out[d + 3] = 255
                    continue
                }
                let da = Int(out[d + 3])
                let oa = a + da * (255 - a) / 255
                guard oa > 0 else { continue }
                for c in 0..<3 {
                    let sc = Int(part.rgba[s + c]), dc = Int(out[d + c])
                    out[d + c] = UInt8(min(255, (sc * a + dc * da * (255 - a) / 255) / oa))
                }
                out[d + 3] = UInt8(oa)
            }
        }
        return CZImage(width: width, height: height, offsetX: offsetX, offsetY: offsetY,
                       canvasWidth: canvasWidth, canvasHeight: canvasHeight, rgba: out)
    }

    public static func isCZ(_ data: Data) -> Bool {
        data.count >= 15 && data[data.startIndex] == 0x43 && data[data.startIndex + 1] == 0x5A
    }

    public init(data: Data) throws {
        let d = [UInt8](data)
        guard d.count >= 15, d[0] == 0x43, d[1] == 0x5A else { throw Failure.notCZ }
        let kind = d[2]
        let headerLength = Int(rd32(d, 4))
        width = Int(rd16(d, 8))
        height = Int(rd16(d, 10))
        var bits = Int(rd16(d, 12))
        guard width > 0, height > 0, width <= 16384, height <= 16384, headerLength <= d.count else {
            throw Failure.corrupt("size \(width)×\(height), header \(headerLength)")
        }
        var ox = 0, oy = 0, cw = 0, ch = 0
        if kind == 0x30 || kind == 0x33 || kind == 0x34, headerLength >= 28 {
            ox = Int(Int16(bitPattern: rd16(d, 16)))
            oy = Int(Int16(bitPattern: rd16(d, 18)))
            cw = Int(rd16(d, 20))
            ch = Int(rd16(d, 22))
        }
        offsetX = ox
        offsetY = oy
        canvasWidth = cw
        canvasHeight = ch
        let pixels = width * height
        var out = [UInt8](repeating: 0, count: pixels * 4)

        switch kind {
        case 0x30: // CZ0
            guard bits == 32 else { throw Failure.unsupported("CZ0 with \(bits) bits") }
            let start = headerLength
            guard start + pixels * 4 <= d.count else { throw Failure.corrupt("CZ0 data short") }
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<(pixels * 4) { o[i] = d[start + i] }
            }

        case 0x31, 0x32: // CZ1, CZ2
            if bits > 32 { bits = 8 } // 0xF8 etc. mark an 8-bit palette
            var offset = headerLength
            var palette: [(UInt8, UInt8, UInt8, UInt8)] = []
            if bits == 4 || bits == 8 {
                let colours = 1 << bits
                guard offset + colours * 4 <= d.count else { throw Failure.corrupt("palette short") }
                for i in 0..<colours {
                    let p = offset + i * 4 // stored BGRA
                    palette.append((d[p + 2], d[p + 1], d[p], d[p + 3]))
                }
                offset += colours * 4
            }
            let raw = kind == 0x31 ? try Self.lzw16(d, from: offset) : try Self.lzw2(d, from: offset)
            switch bits {
            case 4:
                guard raw.count * 2 >= pixels else { throw Failure.corrupt("CZ1 4-bit data short") }
                for i in 0..<pixels {
                    let byte = raw[i / 2]
                    let index = Int(i % 2 == 0 ? byte & 0x0F : byte >> 4)
                    let c = palette[index]
                    out[i * 4] = c.0; out[i * 4 + 1] = c.1; out[i * 4 + 2] = c.2; out[i * 4 + 3] = c.3
                }
            case 8:
                guard raw.count >= pixels else { throw Failure.corrupt("8-bit data short") }
                for i in 0..<pixels {
                    let c = palette[Int(raw[i])]
                    out[i * 4] = c.0; out[i * 4 + 1] = c.1; out[i * 4 + 2] = c.2; out[i * 4 + 3] = c.3
                }
            case 24:
                guard raw.count >= pixels * 3 else { throw Failure.corrupt("24-bit data short") }
                for i in 0..<pixels {
                    out[i * 4] = raw[i * 3]; out[i * 4 + 1] = raw[i * 3 + 1]; out[i * 4 + 2] = raw[i * 3 + 2]
                    out[i * 4 + 3] = 0xFF
                }
            case 32:
                guard raw.count >= pixels * 4 else { throw Failure.corrupt("32-bit data short") }
                out = Array(raw[0..<(pixels * 4)])
            default:
                throw Failure.unsupported("CZ\(kind - 0x30) with \(bits) bits")
            }

        case 0x33: // CZ3
            let raw = try Self.lzw16(d, from: headerLength)
            let bytesPerPixel = bits >> 3
            guard bytesPerPixel == 3 || bytesPerPixel == 4 else { throw Failure.unsupported("CZ3 with \(bits) bits") }
            let line = width * bytesPerPixel
            guard raw.count >= line * height else { throw Failure.corrupt("CZ3 data short") }
            let band = (height + 2) / 3
            var previous = [UInt8](repeating: 0, count: line)
            var current = [UInt8](repeating: 0, count: line)
            for y in 0..<height {
                let base = y * line
                for x in 0..<line {
                    current[x] = y % band == 0 ? raw[base + x] : raw[base + x] &+ previous[x]
                }
                swap(&previous, &current)
                let row = y * width * 4
                if bytesPerPixel == 4 {
                    for x in 0..<line { out[row + x] = previous[x] }
                } else {
                    for x in 0..<width {
                        out[row + x * 4] = previous[x * 3]
                        out[row + x * 4 + 1] = previous[x * 3 + 1]
                        out[row + x * 4 + 2] = previous[x * 3 + 2]
                        out[row + x * 4 + 3] = 0xFF
                    }
                }
            }

        case 0x34: // CZ4
            let raw = try Self.lzw16(d, from: headerLength)
            guard raw.count >= pixels * 4 else { throw Failure.corrupt("CZ4 data short") }
            let band = (height + 2) / 3
            var prevRGB = [UInt8](repeating: 0, count: width * 3)
            var prevA = [UInt8](repeating: 0, count: width)
            let alphaBase = pixels * 3
            for y in 0..<height {
                let rgbRow = y * width * 3
                let aRow = alphaBase + y * width
                let delta = y % band != 0
                for x in 0..<(width * 3) {
                    let v = raw[rgbRow + x]
                    prevRGB[x] = delta ? v &+ prevRGB[x] : v
                }
                for x in 0..<width {
                    let v = raw[aRow + x]
                    prevA[x] = delta ? v &+ prevA[x] : v
                }
                let row = y * width * 4
                for x in 0..<width {
                    out[row + x * 4] = prevRGB[x * 3]
                    out[row + x * 4 + 1] = prevRGB[x * 3 + 1]
                    out[row + x * 4 + 2] = prevRGB[x * 3 + 2]
                    out[row + x * 4 + 3] = prevA[x]
                }
            }

        default:
            throw Failure.unsupported("CZ\(Character(UnicodeScalar(kind)))")
        }
        rgba = out
    }

    // MARK: LZW

    /// Block table at `from`: count, then (compressed size, raw size) per block, then data.
    private static func blocks(_ d: [UInt8], from: Int) throws -> (table: [(Int, Int)], data: Int) {
        guard from + 4 <= d.count else { throw Failure.corrupt("no block table") }
        let count = Int(rd32(d, from))
        guard count < 1 << 20, from + 4 + count * 8 <= d.count else { throw Failure.corrupt("block table") }
        var table: [(Int, Int)] = []
        for i in 0..<count {
            table.append((Int(rd32(d, from + 4 + i * 8)), Int(rd32(d, from + 8 + i * 8))))
        }
        return (table, from + 4 + count * 8)
    }

    /// LZW dictionary as a prefix tree: each code is its prefix code plus one byte, so an
    /// entry is written out by walking back to its root.
    private struct Dictionary {
        var prefix: [Int32] = []
        var last: [UInt8] = []
        var first: [UInt8] = []
        var length: [Int32] = []

        mutating func reset() {
            prefix.removeAll(keepingCapacity: true)
            last.removeAll(keepingCapacity: true)
            first.removeAll(keepingCapacity: true)
            length.removeAll(keepingCapacity: true)
            for i in 0..<256 {
                prefix.append(-1); last.append(UInt8(i)); first.append(UInt8(i)); length.append(1)
            }
        }

        var count: Int { prefix.count }

        mutating func add(prefix p: Int, byte: UInt8) {
            prefix.append(Int32(p)); last.append(byte); first.append(first[p]); length.append(length[p] + 1)
        }

        /// Appends code `c`'s bytes to `out`.
        func write(_ c: Int, to out: inout [UInt8]) {
            let n = Int(length[c])
            let start = out.count
            out.append(contentsOf: repeatElement(0, count: n))
            var code = c
            var i = start + n - 1
            while code >= 0 {
                out[i] = last[code]
                i -= 1
                code = Int(prefix[code])
            }
        }
    }

    /// One LZW block: `next()` yields codes until it returns nil. The format's dictionary
    /// gets an entry for every code, the first included (w starts as the first code's string).
    private static func decodeBlock(_ dict: inout Dictionary, firstCode: Int, out: inout [UInt8],
                                    next: () throws -> Int?) throws {
        dict.reset()
        guard firstCode < dict.count else { throw Failure.corrupt("LZW first code") }
        var w = firstCode
        while let code = try next() {
            let entryFirst: UInt8
            if code < dict.count {
                dict.write(code, to: &out)
                entryFirst = dict.first[code]
                dict.add(prefix: w, byte: entryFirst)
            } else if code == dict.count {
                // w + w[0]: add it, then write it.
                entryFirst = dict.first[w]
                dict.add(prefix: w, byte: entryFirst)
                dict.write(code, to: &out)
            } else {
                throw Failure.corrupt("LZW code \(code)")
            }
            w = code
        }
    }

    /// CZ1/CZ3/CZ4: 16-bit little-endian codes, a fresh dictionary per block.
    static func lzw16(_ d: [UInt8], from: Int) throws -> [UInt8] {
        let (table, start) = try blocks(d, from: from)
        var out: [UInt8] = []
        out.reserveCapacity(table.reduce(0) { $0 + $1.1 })
        var offset = start
        var dict = Dictionary()
        for (codes, _) in table {
            guard offset + codes * 2 <= d.count else { throw Failure.corrupt("LZW block short") }
            guard codes > 0 else { continue }
            var i = 0
            let base = offset
            try decodeBlock(&dict, firstCode: Int(rd16(d, base)), out: &out) {
                guard i < codes else { return nil }
                defer { i += 1 }
                return Int(rd16(d, base + i * 2))
            }
            offset += codes * 2
        }
        return out
    }

    /// CZ2: a bit stream, each code 1 flag bit then 15 bits (flag 0) or 18 bits (flag 1).
    static func lzw2(_ d: [UInt8], from: Int) throws -> [UInt8] {
        let (table, start) = try blocks(d, from: from)
        var out: [UInt8] = []
        var offset = start
        var dict = Dictionary()
        for (size, _) in table {
            guard offset + size <= d.count else { throw Failure.corrupt("LZW2 block short") }
            var bytePos = offset
            var bitPos = 0
            let end = offset + size
            func bits(_ n: Int) -> Int {
                var value = 0
                for i in 0..<n {
                    let byte = bytePos < end ? d[bytePos] : 0
                    value |= Int((byte >> UInt8(bitPos)) & 1) << i
                    bitPos += 1
                    if bitPos == 8 { bitPos = 0; bytePos += 1 }
                }
                return value
            }
            // LuckSystem's w starts as code 0's string; the first code read is decoded too.
            var pending: Int? = nil
            func readCode() -> Int? {
                let code = bits(1) == 0 ? bits(15) : bits(18)
                return bytePos > end ? nil : code
            }
            dict.reset()
            var w = 0
            while let code = pending ?? readCode() {
                pending = nil
                let entryFirst: UInt8
                if code < dict.count {
                    dict.write(code, to: &out)
                    entryFirst = dict.first[code]
                    dict.add(prefix: w, byte: entryFirst)
                } else if code == dict.count {
                    entryFirst = dict.first[w]
                    dict.add(prefix: w, byte: entryFirst)
                    dict.write(code, to: &out)
                } else {
                    throw Failure.corrupt("LZW2 code \(code)")
                }
                w = code
            }
            offset = end
        }
        return out
    }
}

@inline(__always) private func rd16(_ d: [UInt8], _ i: Int) -> UInt16 {
    UInt16(d[i]) | UInt16(d[i + 1]) << 8
}

@inline(__always) private func rd32(_ d: [UInt8], _ i: Int) -> UInt32 {
    UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
}
