import Foundation

/// A Luca System game's resources: the archives under `files/`, with ids resolved the way the
/// scripts use them. Image ids are global across the image archives (each archive starts its
/// numbering at its own first id); voices, music and sound effects come from their own
/// archives by id. A `patch/files` folder can hold loose replacements named like the
/// entries (`BG001A`, `Z513200014`, …) and they win.
public final class LucaGame: @unchecked Sendable {
    public let root: URL
    public let scripts: PAKArchive
    public let images: [PAKArchive]
    public let voices: [PAKArchive]
    public let music: PAKArchive?
    public let soundEffects: PAKArchive?
    public let systemSounds: PAKArchive?
    private let patch: URL?

    private let cacheLock = NSLock()
    private var imageCache: [Int: CZImage] = [:]
    private var imageCacheOrder: [Int] = []
    private var imageCacheBytes = 0
    /// Ids that aren't CZ pictures (MVT movies, missing entries): not read again.
    private var undecodable = Set<Int>()
    /// Decoded pictures kept, by size: a 3840×2160 background alone is 33 MB.
    public var imageCacheLimit = 200 << 20
    /// PARAM.PAK: data tables (the voiced characters, CG gallery, sound adjustments).
    public let params: PAKArchive?
    private var scriptCache: [String: LucaScript] = [:]

    /// `root` holds `files/` (a Steam folder's `base/`); `patch` an optional overlay folder.
    public init(root: URL, patch: URL? = nil) throws {
        self.root = root
        let files = root.appendingPathComponent("files", isDirectory: true)
        func open(_ path: String) -> PAKArchive? {
            try? PAKArchive(url: files.appendingPathComponent(path))
        }
        guard let scripts = open("SCRIPT.PAK") else { throw LucaError.missing("files/SCRIPT.PAK") }
        self.scripts = scripts
        let imageFolder = files.appendingPathComponent("image", isDirectory: true)
        let imageNames = ((try? FileManager.default.contentsOfDirectory(atPath: imageFolder.path)) ?? [])
            .filter { $0.uppercased().hasSuffix(".PAK") }.sorted()
        images = imageNames.compactMap { open("image/\($0)") }
        let voiceFolder = files.appendingPathComponent("voice", isDirectory: true)
        voices = ((try? FileManager.default.contentsOfDirectory(atPath: voiceFolder.path)) ?? [])
            .filter { $0.uppercased().hasSuffix(".PAK") }.sorted().compactMap { open("voice/\($0)") }
        music = open("music/MUSIC.PAK")
        soundEffects = open("se/SE.PAK")
        systemSounds = open("SYSSE.PAK")
        params = open("PARAM.PAK")
        self.patch = patch.map { $0.appendingPathComponent("files", isDirectory: true) }
    }

    /// The characters with their own voice volume (OPTIONS › Voice), from `_voice_param`'s
    /// header: a count, names per character (3: Japanese, English, Chinese), then the names.
    public func voiceCharacters() -> [(japanese: String, english: String)] {
        guard let data = try? params?.data(named: "_voice_param"), data.count > 8 else { return [] }
        let count = Int(data.le32(0)), perCharacter = Int(data.le32(4))
        guard count < 100, perCharacter >= 2, perCharacter < 8 else { return [] }
        var position = data.startIndex + 8
        var names: [String] = []
        for _ in 0..<(count * perCharacter) {
            guard let end = data[position...].firstIndex(of: 0) else { return [] }
            names.append(String(decoding: data[position..<end], as: UTF8.self))
            position = end + 1
        }
        return (0..<count).map { (names[$0 * perCharacter], names[$0 * perCharacter + 1]) }
    }

    // MARK: Scripts

    /// Where a new game starts: the scenario flow script when there is one (REFLECTION BLUE's
    /// `00_シナリオフロー`), else the first story script in SCRIPT.PAK (Harmonia's chapters
    /// run in order from `届けたいメロディー_00章`). Names starting with `_` are data tables.
    public var entryScript: String {
        if scripts.entry(named: "00_シナリオフロー") != nil { return "00_シナリオフロー" }
        return scripts.entries.first { !$0.name.hasPrefix("_") && !$0.name.isEmpty }?.name ?? "00_シナリオフロー"
    }

    /// Every script's name in SCRIPT.PAK order (story scripts and `_` data tables alike).
    public var scriptNames: [String] { scripts.entries.map(\.name).filter { !$0.isEmpty } }

    public func script(named name: String) throws -> LucaScript {
        cacheLock.lock()
        if let cached = scriptCache[name] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        guard let entry = scripts.entry(named: name) else { throw LucaError.missing("script \(name)") }
        let script = try LucaScript(name: entry.name, data: scripts.data(for: entry))
        cacheLock.lock()
        scriptCache[name] = script
        cacheLock.unlock()
        return script
    }

    // MARK: Images

    /// The archive entry for a global image id.
    public func imageEntry(_ id: Int) -> (PAKArchive, PAKArchive.Entry)? {
        for archive in images {
            if let entry = archive.entry(id: id) { return (archive, entry) }
        }
        return nil
    }

    public func imageName(_ id: Int) -> String? { imageEntry(id)?.1.name }

    /// An animated effect (an MVT in BGMOVIE.PAK, numbered among the pictures), or nil when
    /// `id` is a picture.
    public func mvt(_ id: Int) -> (header: WebM.MVTHeader, webm: WebM)? {
        guard let (archive, entry) = imageEntry(id), let data = try? archive.data(for: entry),
              data.prefix(3) == Data("MVT".utf8) else { return nil }
        return try? WebM.mvt(data)
    }

    /// Whether `id` names an MVT (everything in BGMOVIE.PAK is one).
    public func isMVT(_ id: Int) -> Bool {
        imageEntry(id)?.0.url.lastPathComponent.uppercased() == "BGMOVIE.PAK"
    }

    /// A picture's global id by name (any image archive).
    public func imageID(named name: String) -> Int? {
        for archive in images {
            if let entry = archive.entry(named: name) { return entry.id }
        }
        return nil
    }

    private var frames: [Int: (x: Int, y: Int, width: Int, height: Int)] = [:]

    /// For a character face overlay (`F_BS3_RU02010111`), the sprite it belongs to
    /// (`BS3_RU02010111`): the overlay is placed in that sprite's frame.
    public func overlayAnchor(_ id: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let (archive, entry) = imageEntry(id), entry.name.uppercased().hasPrefix("F_"),
              let base = archive.entry(named: String(entry.name.dropFirst(2))) else { return nil }
        return frame(base.id)
    }

    /// A picture's size and placement, from its header only.
    /// Whether picture `id` is a patch the game composes onto a base by name.
    public func hasNamedBase(_ id: Int) -> Bool {
        guard let (archive, entry) = imageEntry(id), let f = frame(id) else { return false }
        if entry.name.uppercased().hasPrefix("F_BS") { return true }
        return patchBase(of: entry, in: archive, area: f.width * f.height) != nil
    }

    public func frame(_ id: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        cacheLock.lock()
        if let cached = frames[id] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        guard let (archive, entry) = imageEntry(id),
              let frame = (try? archive.data(for: entry)).flatMap(CZImage.frame(of:)) else { return nil }
        cacheLock.lock()
        frames[id] = frame
        cacheLock.unlock()
        return frame
    }

    /// Where a character's face is in picture `id` (as `image(id)` returns it): the
    /// rectangle its expression patch covers. A pose's base picture borrows the rectangle of
    /// its first expression.
    public func faceRect(_ id: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let (archive, entry) = imageEntry(id), entry.name.uppercased().hasPrefix("BS") else { return nil }
        var patchEntry: PAKArchive.Entry? = Self.characterBase(entry.name) != nil ? entry : nil
        let baseName = Self.characterBase(entry.name) ?? entry.name
        if patchEntry == nil {
            let stem = String(entry.name.dropLast(2))
            patchEntry = (2...30).lazy.compactMap { archive.entry(named: stem + String(format: "%02d", $0)) }.first
        }
        guard let patchEntry, let baseEntry = archive.entry(named: baseName),
              let patch = (try? archive.data(for: patchEntry)).flatMap(CZImage.frame(of:)),
              let base = (try? archive.data(for: baseEntry)).flatMap(CZImage.frame(of:))
        else { return nil }
        return (patch.x - base.x, patch.y - base.y, patch.width, patch.height)
    }

    private func decode(_ archive: PAKArchive, _ entry: PAKArchive.Entry) -> CZImage? {
        let data = patched(entry.name) ?? (try? archive.data(for: entry))
        guard let data, CZImage.isCZ(data) else { return nil }
        return try? CZImage(data: data)
    }

    /// For a character expression (`BS1_KY03010116`), its pose's base picture
    /// (`BS1_KY03010101`); nil for bases and other pictures.
    /// The picture a patch is drawn over: the nearest `…01` of its set that is a whole picture
    /// (bigger than the patch; for event CGs, at the screen's origin rather than a patch
    /// itself). `cg_sz01_0303` → `cg_sz01_0201` (`cg_sz01_0301` is a patch too);
    /// `BS2_AO01030116` → `BS2_AO01030101`.
    public func patchBase(of entry: PAKArchive.Entry, in archive: PAKArchive, area: Int) -> PAKArchive.Entry? {
        // Large versions (CG_TM01_0102L) patch large bases (CG_TM01_0101L).
        let large = entry.name.hasSuffix("L") || entry.name.hasSuffix("l")
        let name = large ? String(entry.name.dropLast()) : entry.name
        let suffix = large ? String(entry.name.last!) : ""
        guard name.count > 4, name.suffix(2).allSatisfy(\.isNumber) else { return nil }
        var candidates = [String(name.dropLast(2)) + "01"]
        // Event CGs number groups of four digits (_GGNN): earlier groups' 01s too.
        let digits = name.reversed().prefix { $0.isNumber }
        if digits.count == 4, let group = Int(String(digits.reversed()).prefix(2)) {
            let stem = String(name.dropLast(4))
            candidates += stride(from: group - 1, through: 1, by: -1).map { stem + String(format: "%02d01", $0) }
        }
        candidates = candidates.map { $0 + suffix }
        let character = name.uppercased().hasPrefix("BS")
        for candidate in candidates {
            guard let base = archive.entry(named: candidate) ?? (large ? archive.entry(named: String(candidate.dropLast()) + (suffix == "L" ? "l" : "L")) : nil),
                  base.id != entry.id,
                  let frame = (try? archive.data(for: base)).flatMap(CZImage.frame(of:)),
                  frame.width * frame.height > area
            else { continue }
            if character || (frame.x == 0 && frame.y == 0 && frame.width >= 1900) { return base }
        }
        return nil
    }

    static func characterBase(_ name: String) -> String? {
        let upper = name.uppercased()
        guard upper.hasPrefix("BS"), let underscore = upper.firstIndex(of: "_"),
              upper.distance(from: underscore, to: upper.endIndex) >= 9, !upper.hasSuffix("01"),
              upper.suffix(2).allSatisfy(\.isNumber)
        else { return nil }
        return String(name.dropLast(2)) + "01"
    }

    /// Decoded image `id`, cached (the most recent, up to `imageCacheLimit` bytes).
    public func image(_ id: Int) -> CZImage? {
        cacheLock.lock()
        if let cached = imageCache[id] {
            imageCacheOrder.removeAll { $0 == id }
            imageCacheOrder.append(id)
            cacheLock.unlock()
            return cached
        }
        if undecodable.contains(id) { cacheLock.unlock(); return nil }
        cacheLock.unlock()
        guard let (archive, entry) = imageEntry(id), var image = decode(archive, entry) else {
            cacheLock.lock()
            undecodable.insert(id)
            cacheLock.unlock()
            return nil
        }
        // Character expressions are patches over their pose's first picture: BS2_AO01030116 is
        // drawn on BS2_AO01030101. (Event CG patches go over the layer's last whole picture:
        // LucaLayer.baseImageID.)
        if entry.name.uppercased().hasPrefix("F_BS"), let baseEntry = archive.entry(named: String(entry.name.dropFirst(2))),
           let baseImage = self.image(baseEntry.id) {
            // A close-up's face layer (F_BS3_RU02010111) over its sprite (BS3_RU02010111).
            image = baseImage.composited(with: image)
        } else if let baseEntry = patchBase(of: entry, in: archive, area: image.width * image.height),
           let baseImage = self.image(baseEntry.id) {
            image = baseImage.composited(with: image)
        }
        cacheLock.lock()
        if imageCache[id] == nil {
            imageCache[id] = image
            imageCacheOrder.append(id)
            imageCacheBytes += image.rgba.count
        }
        while imageCacheBytes > imageCacheLimit, imageCacheOrder.count > 1 {
            if let old = imageCache.removeValue(forKey: imageCacheOrder.removeFirst()) {
                imageCacheBytes -= old.rgba.count
            }
        }
        cacheLock.unlock()
        return image
    }

    // MARK: Sound

    public func voice(_ id: Int) -> Data? {
        for archive in voices {
            if let entry = archive.entry(id: id) { return patched(entry.name) ?? (try? archive.data(for: entry)) }
        }
        return nil
    }

    /// Whether a voice has a recording (narration carries ids with none).
    public func hasVoice(_ id: Int) -> Bool {
        id > 0 && voices.contains { $0.entry(id: id) != nil }
    }

    public func music(_ id: Int) -> Data? {
        guard let archive = music, let entry = archive.entry(id: id) else { return nil }
        return patched(entry.name) ?? (try? archive.data(for: entry))
    }

    public func soundEffect(_ id: Int) -> Data? {
        guard let archive = soundEffects, let entry = archive.entry(id: id) else { return nil }
        return patched(entry.name) ?? (try? archive.data(for: entry))
    }

    public func systemSound(named name: String) -> Data? {
        guard let archive = systemSounds, let entry = archive.entry(named: name) else { return nil }
        return try? archive.data(for: entry)
    }

    private func patched(_ name: String) -> Data? {
        guard let patch else { return nil }
        for ext in ["", ".cz", ".ogg"] {
            let url = patch.appendingPathComponent(name + ext)
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }
}
