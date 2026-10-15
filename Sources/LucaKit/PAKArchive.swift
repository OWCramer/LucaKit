// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A Luca System `.PAK` archive (Prototype's engine: Summer Pockets REFLECTION BLUE, Little
/// Busters!, AIR …). Format as documented by LuckSystem (github.com/wetor/LuckSystem, MIT).
///
/// Header (little-endian `UInt32`s): header length, file count, first file id, block size,
/// four unknowns, flags. Somewhere after offset 32 a `UInt32` equal to
/// `headerLength / blockSize` precedes the entry table: `fileCount` pairs of
/// (offset in blocks, length in bytes). With flag `0x200` the archive is named: the word
/// before that marker is the offset of a table of NUL-terminated UTF-8 names, one per file.
/// Unnamed archives are addressed by number. Files are referenced by id
/// (`firstID + index`) from scripts, and by name.
public final class PAKArchive: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        public let index: Int
        public let id: Int
        public let name: String
        public let offset: UInt64
        public let length: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case truncated(URL)
        case malformed(URL, String)

        public var description: String {
            switch self {
            case .truncated(let url): "\(url.lastPathComponent): file is truncated"
            case .malformed(let url, let why): "\(url.lastPathComponent): \(why)"
            }
        }
    }

    public let url: URL
    public let firstID: Int
    public let blockSize: Int
    public let flags: UInt32
    public let entries: [Entry]
    private let byName: [String: Int]
    private let handle: FileHandle
    private let lock = NSLock()

    public var isNamed: Bool { flags & 0x200 != 0 }

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let lengthBytes = try Self.read(handle, at: 0, count: 4, url: url)
        let headerLength = Int(lengthBytes.le32(0))
        guard headerLength >= 40, headerLength < 64 << 20 else {
            throw Failure.malformed(url, "header length \(headerLength)")
        }
        let header = try Self.read(handle, at: 0, count: headerLength, url: url)
        let count = Int(header.le32(4))
        firstID = Int(header.le32(8))
        blockSize = Int(header.le32(12))
        flags = header.le32(32)
        guard blockSize > 0 else { throw Failure.malformed(url, "block size 0") }
        let marker = UInt32(headerLength / blockSize)
        var tablePos = 32
        while tablePos + 4 <= header.count, header.le32(tablePos) != marker { tablePos += 4 }
        guard tablePos + 8 * count <= header.count else {
            throw Failure.malformed(url, "entry table not found")
        }
        // LuckSystem reads the table starting at the marker itself: the marker is the first
        // entry's offset (data starts right after the header).
        var names: [String] = []
        if flags & 0x200 != 0 {
            var offset = Int(header.le32(tablePos - 4))
            for _ in 0..<count {
                guard let end = header[offset...].firstIndex(of: 0) else {
                    throw Failure.malformed(url, "name table runs off the header")
                }
                names.append(String(decoding: header[offset..<end], as: UTF8.self))
                offset = end + 1
            }
        }
        var entries: [Entry] = []
        var byName: [String: Int] = [:]
        entries.reserveCapacity(count)
        for index in 0..<count {
            let base = tablePos + 8 * index
            let blocks = UInt64(header.le32(base))
            let length = Int(header.le32(base + 4))
            let name = names.isEmpty ? String(index) : names[index]
            entries.append(Entry(index: index, id: firstID + index, name: name,
                                 offset: blocks * UInt64(blockSize), length: length))
            byName[name.uppercased()] = index
        }
        self.entries = entries
        self.byName = byName
    }

    deinit { try? handle.close() }

    public func entry(named name: String) -> Entry? {
        byName[name.uppercased()].map { entries[$0] }
    }

    public func entry(id: Int) -> Entry? {
        let index = id - firstID
        return entries.indices.contains(index) ? entries[index] : nil
    }

    public func data(for entry: Entry) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try Self.read(handle, at: entry.offset, count: entry.length, url: url)
    }

    public func data(named name: String) throws -> Data? {
        try entry(named: name).map { try data(for: $0) }
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int, url: URL) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw Failure.truncated(url) }
        return data
    }
}

extension Data {
    @inline(__always) func le16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    @inline(__always) func le32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
