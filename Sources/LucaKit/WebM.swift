// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A WebM (Matroska) file read just far enough to play it: its tracks and the frames of each,
/// in file order. REFLECTION BLUE's movies and animated effects (MVT) are VP9 video with
/// Vorbis audio; neither has a player on iOS, so Shiori decodes them itself.
public struct WebM: Sendable {
    public struct Track: Sendable {
        public var number: Int
        public var codec: String
        public var width = 0
        public var height = 0
        public var sampleRate: Double = 0
        public var channels = 0
        public var codecPrivate = Data()
        public var isVideo: Bool { codec.hasPrefix("V_") }
        public var isAudio: Bool { codec.hasPrefix("A_") }
    }

    public struct Frame: Sendable {
        public var track: Int
        /// Seconds from the start.
        public var time: Double
        public var keyframe: Bool
        public var data: Data
    }

    public enum Failure: Error { case notWebM, truncated }

    public let tracks: [Track]
    public let frames: [Frame]
    public let duration: Double

    public var video: Track? { tracks.first { $0.isVideo } }
    public var audio: Track? { tracks.first { $0.isAudio } }

    /// `data` starts with the EBML header (an MVT's 32-byte header is skipped by `mvt(_:)`).
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        var reader = Reader(bytes: bytes)
        guard reader.peekID() == 0x1A45DFA3 else { throw Failure.notWebM }
        var tracks: [Track] = []
        var frames: [Frame] = []
        var scale = 1_000_000.0 // ns per timecode
        var duration = 0.0
        var clusterTime = 0.0

        // Walk the tree, descending into master elements we care about.
        let masters: Set<UInt32> = [0x18538067, 0x1654AE6B, 0xAE, 0xE0, 0xE1, 0x1F43B675, 0xA0, 0x1549A966]
        var trackStack: Track?
        var ends: [(id: UInt32, end: Int)] = []
        while reader.position < bytes.count {
            while let last = ends.last, reader.position >= last.end {
                ends.removeLast()
                if last.id == 0xAE, let track = trackStack {
                    tracks.append(track)
                    trackStack = nil
                }
            }
            guard let id = reader.readID(), let size = reader.readSize() else { break }
            let start = reader.position
            let end = size == Int.max ? bytes.count : min(bytes.count, start + size)
            if masters.contains(id) {
                if id == 0xAE { trackStack = Track(number: 0, codec: "") }
                ends.append((id, end))
                continue
            }
            switch id {
            case 0x2AD7B1: scale = Double(reader.uint(start, end))
            case 0x4489: duration = reader.float(start, end)
            case 0xD7: trackStack?.number = Int(reader.uint(start, end))
            case 0x86: trackStack?.codec = String(decoding: bytes[start..<end], as: UTF8.self)
            case 0x63A2: trackStack?.codecPrivate = Data(bytes[start..<end])
            case 0xB0: trackStack?.width = Int(reader.uint(start, end))
            case 0xBA: trackStack?.height = Int(reader.uint(start, end))
            case 0xB5: trackStack?.sampleRate = reader.float(start, end)
            case 0x9F: trackStack?.channels = Int(reader.uint(start, end))
            case 0xE7: clusterTime = Double(reader.uint(start, end))
            case 0xA3, 0xA1: // SimpleBlock, Block
                frames.append(contentsOf: Self.block(bytes, data, start, end, clusterTime: clusterTime, scale: scale,
                                                     simple: id == 0xA3))
            default:
                break
            }
            reader.position = end
        }
        if let track = trackStack { tracks.append(track) }
        self.tracks = tracks
        self.frames = frames
        self.duration = duration * scale / 1e9
    }

    /// A block's frames, unpacking Xiph, EBML and fixed-size lacing.
    private static func block(_ b: [UInt8], _ source: Data, _ start: Int, _ end: Int, clusterTime: Double, scale: Double,
                              simple: Bool) -> [Frame] {
        var r = Reader(bytes: b)
        r.position = start
        guard let track = r.readSize(), r.position + 3 <= end else { return [] }
        let relative = Int16(bitPattern: UInt16(b[r.position]) << 8 | UInt16(b[r.position + 1]))
        let flags = b[r.position + 2]
        r.position += 3
        let time = (clusterTime + Double(relative)) * scale / 1e9
        let keyframe = simple ? flags & 0x80 != 0 : true
        var sizes: [Int] = []
        switch (flags >> 1) & 3 {
        case 0:
            sizes = [end - r.position]
        case 1: // Xiph
            let count = Int(b[r.position]) + 1
            r.position += 1
            for _ in 0..<(count - 1) {
                var size = 0
                while r.position < end {
                    let v = Int(b[r.position]); r.position += 1
                    size += v
                    if v < 255 { break }
                }
                sizes.append(size)
            }
            sizes.append(end - r.position - sizes.reduce(0, +))
        case 3: // EBML
            let count = Int(b[r.position]) + 1
            r.position += 1
            guard var size = r.readSize() else { return [] }
            sizes.append(size)
            for _ in 1..<(count - 1) {
                let before = r.position
                guard let raw = r.readSize() else { return [] }
                let length = r.position - before
                let bias = (1 << (7 * length - 1)) - 1
                size += raw - bias
                sizes.append(size)
            }
            sizes.append(end - r.position - sizes.reduce(0, +))
        default: // fixed
            let count = Int(b[r.position]) + 1
            r.position += 1
            sizes = Array(repeating: (end - r.position) / count, count: count)
        }
        var frames: [Frame] = []
        for size in sizes where size > 0 && r.position + size <= end {
            // A slice of the source (no copy: the source is usually a mapped file).
            let from = source.startIndex + r.position
            frames.append(Frame(track: track, time: time, keyframe: keyframe, data: source[from..<(from + size)]))
            r.position += size
        }
        return frames
    }

    // MARK: Vorbis → Ogg

    /// The audio track as an Ogg Vorbis stream (the codec headers from CodecPrivate, then each
    /// packet on its own page), for an Ogg Vorbis decoder.
    public func vorbisAsOgg() -> Data? {
        guard let audio, audio.codec == "A_VORBIS" else { return nil }
        let p = [UInt8](audio.codecPrivate)
        guard p.count > 3 else { return nil }
        // Xiph-laced: count - 1, then the first two sizes, then the three headers.
        var i = 1
        var sizes: [Int] = []
        for _ in 0..<Int(p[0]) {
            var size = 0
            while i < p.count {
                let v = Int(p[i]); i += 1
                size += v
                if v < 255 { break }
            }
            sizes.append(size)
        }
        var headers: [ArraySlice<UInt8>] = []
        for size in sizes {
            guard i + size <= p.count else { return nil }
            headers.append(p[i..<(i + size)]); i += size
        }
        headers.append(p[i...])
        guard headers.count == 3 else { return nil }

        var ogg = OggWriter(serial: 0x4C554341)
        ogg.page([headers[0]], granule: 0, bos: true)
        ogg.page([headers[1], headers[2]], granule: 0)
        let packets = frames.filter { $0.track == audio.number }
        for (n, packet) in packets.enumerated() {
            // Unknown sample positions (-1) are allowed; the decoder counts for itself.
            ogg.page([ArraySlice(packet.data)], granule: UInt64.max, eos: n == packets.count - 1)
        }
        return Data(ogg.bytes)
    }

    // MARK: MVT

    /// An MVT (BGMOVIE.PAK): a 32-byte header, then WebM. The header carries the picture's
    /// size, the size it shows at and the frame rate.
    public struct MVTHeader: Sendable {
        public var width: Int
        public var height: Int
        public var displayWidth: Int
        public var displayHeight: Int
        public var fps: Int
        /// The video holds its alpha below the picture (the top half is colour).
        public var alphaBelow: Bool { displayHeight * 2 == height && displayWidth == width }
        /// The video holds its alpha right of the picture (the left half is colour).
        public var alphaRight: Bool { displayWidth * 2 == width && displayHeight == height }
        /// The size it covers on the 1920×1080 screen: the display size, or the whole video
        /// when the alpha is packed beside the picture.
        public var shownWidth: Int { alphaRight || alphaBelow ? width : displayWidth }
        public var shownHeight: Int { alphaRight || alphaBelow ? height : displayHeight }
    }

    public static func mvt(_ data: Data) throws -> (header: MVTHeader, webm: WebM) {
        let b = [UInt8](data.prefix(64))
        guard b.count >= 32, b[0] == 0x4D, b[1] == 0x56, b[2] == 0x54 else { throw Failure.notWebM }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        let header = MVTHeader(width: u16(4), height: u16(6), displayWidth: u16(8), displayHeight: u16(10), fps: Int(b[20]))
        guard let start = (0..<min(64, b.count - 3)).first(where: { b[$0] == 0x1A && b[$0 + 1] == 0x45 && b[$0 + 2] == 0xDF && b[$0 + 3] == 0xA3 })
        else { throw Failure.notWebM }
        return (header, try WebM(data: data.subdata(in: (data.startIndex + start)..<data.endIndex)))
    }

    // MARK: EBML

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        func peekID() -> UInt32? {
            var copy = self
            return copy.readID()
        }

        mutating func readID() -> UInt32? {
            guard position < bytes.count else { return nil }
            let first = bytes[position]
            var length = 1
            while length <= 4, first & (0x80 >> (length - 1)) == 0 { length += 1 }
            guard length <= 4, position + length <= bytes.count else { return nil }
            var value: UInt32 = 0
            for i in 0..<length { value = value << 8 | UInt32(bytes[position + i]) }
            position += length
            return value
        }

        /// A variable-length size; all ones means unknown (`Int.max`).
        mutating func readSize() -> Int? {
            guard position < bytes.count else { return nil }
            let first = bytes[position]
            var length = 1
            while length <= 8, first & (0x80 >> (length - 1)) == 0 { length += 1 }
            guard length <= 8, position + length <= bytes.count else { return nil }
            var value = UInt64(first & (0xFF >> length))
            var allOnes = value == UInt64(0xFF >> length)
            for i in 1..<length {
                value = value << 8 | UInt64(bytes[position + i])
                if bytes[position + i] != 0xFF { allOnes = false }
            }
            position += length
            return allOnes ? Int.max : Int(value)
        }

        func uint(_ start: Int, _ end: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in start..<end { v = v << 8 | UInt64(bytes[i]) }
            return v
        }

        func float(_ start: Int, _ end: Int) -> Double {
            let raw = uint(start, end)
            switch end - start {
            case 4: return Double(Float(bitPattern: UInt32(raw)))
            case 8: return Double(bitPattern: raw)
            default: return 0
            }
        }
    }
}

/// Writes Ogg pages.
struct OggWriter {
    let serial: UInt32
    var sequence: UInt32 = 0
    var bytes: [UInt8] = []

    init(serial: UInt32) { self.serial = serial }

    mutating func page(_ packets: [ArraySlice<UInt8>], granule: UInt64, bos: Bool = false, eos: Bool = false) {
        var segments: [UInt8] = []
        for packet in packets {
            var left = packet.count
            while left >= 255 { segments.append(255); left -= 255 }
            segments.append(UInt8(left))
        }
        // A page holds at most 255 segments; the packets here are far smaller.
        var page: [UInt8] = Array("OggS".utf8) + [0, (bos ? 2 : 0) | (eos ? 4 : 0)]
        for i in 0..<8 { page.append(UInt8(truncatingIfNeeded: granule >> (8 * UInt64(i)))) }
        for v in [serial, sequence, 0] { for i in 0..<4 { page.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
        page.append(UInt8(segments.count))
        page += segments
        for packet in packets { page += packet }
        let crc = Self.crc(page)
        for i in 0..<4 { page[22 + i] = UInt8(truncatingIfNeeded: crc >> (8 * UInt32(i))) }
        bytes += page
        sequence += 1
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var r = UInt32(n) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func crc(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data { crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(byte))] }
        return crc
    }
}
