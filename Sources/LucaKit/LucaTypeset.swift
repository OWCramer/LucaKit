import Foundation

/// Lays text out in the game's bitmap fonts and draws it as the PC game does: glyphs from the
/// atlas, wrapped at spaces (anywhere in text without them), with a dark outline.
public struct LucaTypeset: Sendable {
    public struct Placed: Sendable {
        /// Which `Character` of the text this is.
        public var character: Int
        public var x: Int
        public var line: Int
        public var advance: Int
        var font: Int
        var glyph: LucaFont.Glyph
    }

    public let placed: [Placed]
    public let lineCount: Int
    public let lineHeight: Int
    public let width: Int
    private let fonts: [LucaFont]

    public var height: Int { max(1, lineCount) * lineHeight }
    /// How wide the text actually runs (the widest line), plus room for an outline.
    public var usedWidth: Int { min(width, (placed.map { $0.x + $0.advance }.max() ?? 0) + 4) }

    /// `fonts` are tried in order for each character (the size's font, its patch font, then a
    /// larger size with more characters).
    public init(_ text: String, fonts: [LucaFont], width: Int, lineHeight: Int) {
        self.fonts = fonts
        self.width = width
        self.lineHeight = lineHeight
        let space = fonts.first.map { $0.size / 4 } ?? 8
        // Each character with its glyph (or nil: a gap of `space`).
        let characters = Array(text)
        func look(_ c: Character) -> (font: Int, glyph: LucaFont.Glyph)? {
            guard let scalar = c.unicodeScalars.first else { return nil }
            for (i, font) in fonts.enumerated() { if let g = font.glyph(scalar) { return (i, g) } }
            return nil
        }
        var placed: [Placed] = []
        var x = 0, line = 0
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == "\n" { x = 0; line += 1; i += 1; continue }
            if c == " " {
                x += look(c)?.glyph.advance ?? space
                i += 1
                continue
            }
            // A word: up to the next space or newline (one character for text without spaces).
            var end = i
            if c.isASCII || c.isLetter && c.unicodeScalars.first!.value < 0x2E80 {
                while end < characters.count, characters[end] != " ", characters[end] != "\n" { end += 1 }
            } else {
                end = i + 1
            }
            let word = (i..<end).map { (index: $0, found: look(characters[$0])) }
            let wordWidth = word.reduce(0) { $0 + ($1.found?.glyph.advance ?? space) }
            if x > 0, x + wordWidth > width, wordWidth <= width { x = 0; line += 1 }
            for part in word {
                let advance = part.found?.glyph.advance ?? space
                if x > 0, x + advance > width { x = 0; line += 1 }
                if let found = part.found {
                    placed.append(Placed(character: part.index, x: x, line: line, advance: advance,
                                         font: found.font, glyph: found.glyph))
                }
                x += advance
            }
            i = end
        }
        self.placed = placed
        lineCount = characters.isEmpty ? 0 : line + 1
    }

    /// The text drawn: premultiplied RGBA, `usedWidth` × `height`, glyphs in `fill` over an outline
    /// `outlineWidth` pixels wide in `outline` (straight 0–255 RGB).
    public func render(fill: (UInt8, UInt8, UInt8), outline: (UInt8, UInt8, UInt8), outlineWidth: Int) -> [UInt8] {
        let w = usedWidth, h = height
        // Coverage of the glyphs, then of the outline (the coverage spread by outlineWidth).
        var ink = [UInt8](repeating: 0, count: w * h)
        for p in placed {
            let font = fonts[p.font]
            let top = p.line * lineHeight + (lineHeight - font.cell) / 2
            for y in 0..<font.cell {
                let ty = top + y
                guard ty >= 0, ty < h else { continue }
                let row = (p.glyph.cellY + y) * font.atlas.width + p.glyph.cellX
                for x in 0..<font.cell {
                    let tx = p.x + x
                    guard tx >= 0, tx < w else { continue }
                    let a = font.atlas.rgba[(row + x) * 4 + 3]
                    if a > ink[ty * w + tx] { ink[ty * w + tx] = a }
                }
            }
        }
        var spread = ink
        if outlineWidth > 0 {
            // Separable max filter: rows, then columns.
            var rows = ink
            for y in 0..<h {
                for x in 0..<w {
                    var m: UInt8 = 0
                    for dx in -outlineWidth...outlineWidth {
                        let sx = x + dx
                        if sx >= 0, sx < w, ink[y * w + sx] > m { m = ink[y * w + sx] }
                    }
                    rows[y * w + x] = m
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var m: UInt8 = 0
                    for dy in -outlineWidth...outlineWidth {
                        let sy = y + dy
                        if sy >= 0, sy < h, rows[sy * w + x] > m { m = rows[sy * w + x] }
                    }
                    spread[y * w + x] = m
                }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = Int(ink[i]), o = Int(spread[i])
            guard o > 0 || a > 0 else { continue }
            // Fill over outline, premultiplied.
            let alpha = a + o * (255 - a) / 255
            out[i * 4] = UInt8((Int(fill.0) * a + Int(outline.0) * o * (255 - a) / 255) / 255)
            out[i * 4 + 1] = UInt8((Int(fill.1) * a + Int(outline.1) * o * (255 - a) / 255) / 255)
            out[i * 4 + 2] = UInt8((Int(fill.2) * a + Int(outline.2) * o * (255 - a) / 255) / 255)
            out[i * 4 + 3] = UInt8(alpha)
        }
        return out
    }

    /// Rectangles (x, y, width, height) covering the first `count` characters, line by line,
    /// for revealing the text as it types.
    public func revealed(_ count: Int) -> [(x: Int, y: Int, width: Int, height: Int)] {
        var lines: [Int: (start: Int, end: Int)] = [:]
        for p in placed where p.character < count {
            let current = lines[p.line] ?? (p.x, p.x + p.advance)
            lines[p.line] = (min(current.start, p.x), max(current.end, p.x + p.advance))
        }
        return lines.sorted { $0.key < $1.key }.map {
            (x: max(0, $0.value.start - 4), y: $0.key * lineHeight, width: $0.value.end - $0.value.start + 8, height: lineHeight)
        }
    }
}
