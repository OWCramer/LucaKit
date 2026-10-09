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

    /// Decoded image `id`, cached (the most recent 48).
    public func image(_ id: Int) -> CZImage? {
        cacheLock.lock()
        if let cached = imageCache[id] {
            imageCacheOrder.removeAll { $0 == id }
            imageCacheOrder.append(id)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let (archive, entry) = imageEntry(id) else { return nil }
        let data = patched(entry.name) ?? (try? archive.data(for: entry))
        guard let data, CZImage.isCZ(data), let image = try? CZImage(data: data) else { return nil }
        cacheLock.lock()
        imageCache[id] = image
        imageCacheOrder.append(id)
        while imageCacheOrder.count > 48 {
            imageCache.removeValue(forKey: imageCacheOrder.removeFirst())
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
