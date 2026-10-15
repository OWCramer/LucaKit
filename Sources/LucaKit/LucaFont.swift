// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// One size of one of the game's bitmap fonts (`files/font_win32_1920/`): a CZ2 atlas of glyphs
/// in a grid (`FONT_GOTHIC1.PAK` and the others, one picture per size) and its info table
/// (`FONT__INFO.PAK`, `info<size>`):
///
///     u16 size, u16 cell, u16 columns, u16 count
///     count × (u8 x, u8 width, u8 extra)          per glyph
///     65536 × u16                                 character → glyph
///     65536 × u16                                 glyph → character
///
/// Glyph `i` fills cell `i % columns, i / columns` of `cell` pixels, drawn from its left edge.
/// The small `FONT_PATCH_*` fonts add a few glyphs over the main ones.
public struct LucaFont: Sendable {
    public struct Glyph: Sendable {
        /// The glyph's cell in the atlas.
        public var cellX: Int
        public var cellY: Int
        /// Left edge of the ink within the cell, and how far the pen moves on.
        public var x: Int
        public var advance: Int
        public var extra: Int
    }

    public let size: Int
    public let cell: Int
    public let atlas: CZImage
    private let columns: Int
    private let records: Data
    private let table: Data
    private let tableStart: Int
    private let count: Int

    public init?(info: Data, atlas: CZImage) {
        guard info.count >= 8 else { return nil }
        size = Int(info.le16(0))
        cell = Int(info.le16(2))
        columns = Int(info.le16(4))
        count = Int(info.le16(6))
        tableStart = 8 + 3 * count
        guard cell > 0, columns > 0, info.count >= tableStart + 65536 * 2 else { return nil }
        records = info
        table = info
        self.atlas = atlas
    }

    /// The glyph for `scalar`, or nil when the font has none (index 0 is the full-width space,
    /// which unmapped characters also point at).
    public func glyph(_ scalar: Unicode.Scalar) -> Glyph? {
        guard scalar.value < 65536 else { return nil }
        let index = Int(table.le16(tableStart + Int(scalar.value) * 2))
        guard index < count, index > 0 || scalar.value == 0x3000 else { return nil }
        let r = records.startIndex + 8 + 3 * index
        return Glyph(cellX: (index % columns) * cell, cellY: (index / columns) * cell,
                     x: Int(records[r]), advance: Int(records[r + 1]), extra: Int(records[r + 2]))
    }
}

extension LucaGame {
    /// The faces in `font_win32_1920`, as the OPTIONS Font setting names them.
    public static let fontFaces = ["GOTHIC1", "GOTHIC2", "GOTHIC3", "MINCHO", "MODERN"]

    /// Font `face` (`GOTHIC1`…) at `size` pixels, and its patch font when there is one.
    public func font(face: String, size: Int) -> (main: LucaFont, patch: LucaFont?)? {
        let folder = root.appendingPathComponent("files/font_win32_1920", isDirectory: true)
        func load(info infoName: String, atlas atlasName: String, entry: String) -> LucaFont? {
            guard let infos = try? PAKArchive(url: folder.appendingPathComponent(infoName)),
                  let atlases = try? PAKArchive(url: folder.appendingPathComponent(atlasName)),
                  let infoEntry = infos.entry(named: entry),
                  let position = infos.entries.firstIndex(where: { $0.id == infoEntry.id }),
                  atlases.entries.indices.contains(position),
                  let info = try? infos.data(for: infoEntry),
                  let atlas = try? CZImage(data: atlases.data(for: atlases.entries[position])) else { return nil }
            return LucaFont(info: info, atlas: atlas)
        }
        guard let main = load(info: "FONT__INFO.PAK", atlas: "FONT_\(face).PAK", entry: "info\(size)") else { return nil }
        let patch = load(info: "FONT_PATCH__INFO.PAK", atlas: "FONT_PATCH_\(face).PAK", entry: "patch_info\(size)")
        return (main, patch)
    }

    /// The sizes `FONT__INFO.PAK` has.
    public var fontSizes: [Int] {
        let folder = root.appendingPathComponent("files/font_win32_1920", isDirectory: true)
        guard let infos = try? PAKArchive(url: folder.appendingPathComponent("FONT__INFO.PAK")) else { return [] }
        return infos.entries.compactMap { Int($0.name.dropFirst(4)) }
    }
}
