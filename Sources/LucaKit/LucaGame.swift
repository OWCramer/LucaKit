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
        self.patch = patch.map { $0.appendingPathComponent("files", isDirectory: true) }
    }

    // MARK: Scripts

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

    private func decode(_ archive: PAKArchive, _ entry: PAKArchive.Entry) -> CZImage? {
        let data = patched(entry.name) ?? (try? archive.data(for: entry))
        guard let data, CZImage.isCZ(data) else { return nil }
        return try? CZImage(data: data)
    }

    /// For a character expression (`BS1_KY03010116`), its pose's base picture
    /// (`BS1_KY03010101`); nil for bases and other pictures.
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
        // Character expressions are face patches over the pose's first picture: BS2_AO01030116
        // is drawn on BS2_AO01030101.
        if let base = Self.characterBase(entry.name), let baseEntry = archive.entry(named: base),
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
