import CoreGraphics
import Foundation
import ImageIO
import LucaKit
import UniformTypeIdentifiers

/// luca-cli — Luca System developer tool.
///   luca-cli list <pak>                     entries of an archive
///   luca-cli scripts <SCRIPT.PAK>           script names with instruction counts
///   luca-cli dump <SCRIPT.PAK> <script>     a script, one instruction per line
///   luca-cli ops <SCRIPT.PAK>               opcode usage across every script
///   luca-cli png <pak> <entry> <out.png>    a CZ image as PNG
///   luca-cli play <base folder> <out dir> [clicks] [script]
///                                           runs the game headless, clicking through,
///                                           and writes a frame per line of text
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else { fail("usage: luca-cli list|scripts|dump|ops|png …") }
let rest = Array(args.dropFirst())

func pak(_ path: String) -> PAKArchive {
    do { return try PAKArchive(url: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
}

func describe(_ op: LucaOp) -> String {
    switch op {
    case .branch(let t, let e, let target): return "\(t ? "IFY" : "IFN") \"\(e)\" → @\(target)"
    case .goto(let target): return "GOTO @\(target)"
    case .gosub(let v, let target): return "GOSUB \(v) @\(target)"
    case .jump(let s, let target): return "JUMP \(s)\(target.map { " @\($0)" } ?? "")"
    case .farcall(let v, let s, let target): return "FARCALL \(v) \(s) @\(target)"
    case .message(let voice, let jp, let en, _, let extra): return "MESSAGE voice=\(voice) en=\"\(en)\" jp=\"\(jp)\" \(extra)"
    case .select(let values, _, let en, _, let extra): return "SELECT \(values) en=\"\(en)\" \(extra)"
    case .varstrSet(let f, let v, _, let en, _): return "VARSTR_SET \(f) var=\(v) en=\"\(en)\""
    case .logBegin(let v, let flag, let jp, let en, _): return "LOG_BEGIN \(v) \(flag) en=\"\(en)\" jp=\"\(jp)\""
    case .dialog(let values, let jp): return "DIALOG \(values) \"\(jp)\""
    case .movie(let f, let extra): return "MOVIE \(f) \(extra)"
    case .expression(let op, let v, let text, let values): return "\(op) \(v) \(text ?? "") \(values)"
    case .raw(let name, let values, let tail): return "\(name) \(values)\(tail.map { " +\($0)" } ?? "")"
    }
}

switch command {
case "list":
    guard let path = rest.first else { fail("list <pak>") }
    let archive = pak(path)
    print("\(archive.entries.count) entries, first id \(archive.firstID), block \(archive.blockSize), flags 0x\(String(archive.flags, radix: 16))")
    for e in archive.entries {
        let head = (try? archive.data(for: e).prefix(4)).map { String(decoding: $0.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self) } ?? ""
        print("\(e.id)\t\(e.name)\t\(e.length)\t\(head)")
    }

case "scripts":
    guard let path = rest.first else { fail("scripts <SCRIPT.PAK>") }
    let archive = pak(path)
    for e in archive.entries {
        do {
            let s = try LucaScript(name: e.name, data: archive.data(for: e))
            print("\(e.id)\t\(e.name)\t\(s.instructions.count)")
        } catch { print("\(e.id)\t\(e.name)\tERROR \(error)") }
    }

case "dump":
    guard rest.count >= 2 else { fail("dump <SCRIPT.PAK> <script>") }
    let archive = pak(rest[0])
    guard let entry = archive.entry(named: rest[1]) ?? Int(rest[1]).flatMap(archive.entry(id:)) else { fail("no script \(rest[1])") }
    do {
        let s = try LucaScript(name: entry.name, data: archive.data(for: entry))
        let hex = rest.contains("--hex")
        for i in s.instructions {
            let fixed = i.fixed.isEmpty ? "" : " \(i.fixed)"
            let op = LucaOp.decode(i)
            var line = "\(i.position)\t\(describe(op))\(fixed)"
            if hex, case .raw = op {
                line += "\t| " + i.params.map { String(format: "%02x", $0) }.joined(separator: " ")
            }
            print(line)
        }
    } catch { fail("\(error)") }

case "ops":
    guard let path = rest.first else { fail("ops <SCRIPT.PAK>") }
    let archive = pak(path)
    var counts: [String: Int] = [:]
    var lengths: [String: Set<Int>] = [:]
    for e in archive.entries {
        guard let s = try? LucaScript(name: e.name, data: archive.data(for: e)) else { continue }
        for i in s.instructions {
            let name = LucaOpcodes.name(i.opcode)
            counts[name, default: 0] += 1
            lengths[name, default: []].insert(i.params.count + i.fixed.count * 2)
        }
    }
    for (name, n) in counts.sorted(by: { $0.value > $1.value }) {
        print("\(name)\t\(n)\tlengths \(lengths[name]!.sorted().prefix(12))")
    }

case "png":
    guard rest.count >= 3 else { fail("png <pak> <entry> <out.png>") }
    let archive = pak(rest[0])
    guard let entry = archive.entry(named: rest[1]) ?? Int(rest[1]).flatMap(archive.entry(id:)) else { fail("no entry \(rest[1])") }
    do {
        let image = try CZImage(data: archive.data(for: entry))
        print("\(image.width)×\(image.height) offset \(image.offsetX),\(image.offsetY) canvas \(image.canvasWidth)×\(image.canvasHeight)")
        let provider = CGDataProvider(data: Data(image.rgba) as CFData)!
        let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var output = cg
        // LUCA_GREY=1: over mid grey, to see white-on-transparent art.
        if ProcessInfo.processInfo.environment["LUCA_GREY"] != nil,
           let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            output = ctx.makeImage() ?? cg
        }
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: rest[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, output, nil)
        CGImageDestinationFinalize(dest)
    } catch { fail("\(error)") }

case "play":
    guard rest.count >= 2 else { fail("play <base folder> <out dir> [clicks] [script]") }
    let out = URL(fileURLWithPath: rest[1])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let clicks = rest.count > 2 ? Int(rest[2]) ?? 20 : 20
    do {
        let game = try LucaGame(root: URL(fileURLWithPath: rest[0]))
        let player = rest.count > 3 ? try LucaPlayer(game: game, script: rest[3]) : try LucaPlayer(game: game)
        var shown = 0
        var frames = 0
        var mapVisits = 0
        var lastLine: LucaPlayer.State?
        if let resume = ProcessInfo.processInfo.environment["LUCA_RESUME"],
           let data = FileManager.default.contents(atPath: resume) {
            try player.restore(JSONDecoder().decode(LucaPlayer.State.self, from: data))
            print("resumed from \(resume) at \(player.currentScript)")
        }
        while shown < clicks, !player.finished, frames < 2_000_000 {
            player.tick()
            frames += 1
            if let movie = player.movie {
                print("MOVIE \(movie)")
                if ProcessInfo.processInfo.environment["LUCA_STOP_AT_MOVIE"] != nil, let lastLine {
                    try JSONEncoder().encode(lastLine).write(to: out.appendingPathComponent("before-movie.json"))
                    print("stopped before the movie; state of the line before it saved")
                    break
                }
                player.movieFinished()
            }
            for sound in player.sounds { print("  sound \(sound)") }
            for notice in player.notices { print("NOTICE \(notice)") }
            player.notices.removeAll()
            player.sounds.removeAll()
            if player.isWaitingForClick { lastLine = player.saveState() }
            if player.isWaitingForClick, player.transition == nil {
                if let m = player.message {
                    print("[\(player.currentScript)@\(player.currentPosition) f\(frames)] #\(shown) \(m.speaker.map { "\($0): " } ?? "")\(m.text)")
                    if ProcessInfo.processInfo.environment["LUCA_LAYERS"] != nil {
                        for l in player.sortedLayers {
                            print("    layer \(String(l.number, radix: 16)) \(player.game.imageName(l.imageID) ?? "?")(\(l.imageID)) at \(l.x),\(l.y) a\(l.alpha) s\(l.scale) b\(l.blend)")
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["LUCA_NO_PNG"] == nil {
                    renderStage(player, to: out.appendingPathComponent(String(format: "%03d.png", shown)))
                }
                shown += 1
                player.click()
            } else if let choices = player.choices {
                if player.choicePrompt != nil, ProcessInfo.processInfo.environment["LUCA_STOP_AT_MAP"] != nil {
                    print("MAP \(choices): stopping")
                    break
                }
                // LUCA_MAP_PICK=Shiroha follows a heroine at every map.
                var pick = 0
                if player.choicePrompt != nil, let wanted = ProcessInfo.processInfo.environment["LUCA_MAP_PICK"] {
                    // Of the places leading to her, take each in turn (some only say she isn't there).
                    let matches = choices.indices.filter { choices[$0] == wanted }
                    if !matches.isEmpty { pick = matches[mapVisits % matches.count] }
                    mapVisits += 1
                    print("  places \(zip(choices, player.choiceDetails.map { $0 ?? "" }).map { "\($0.0): \($0.1)" })")
                }
                print("CHOICE \(choices) → \(pick)")
                player.choose(pick)
            }
        }
        if let failure = player.failure { print("STOPPED: \(failure)") }
        let state = try JSONEncoder().encode(player.saveState())
        try state.write(to: out.appendingPathComponent("state.json"))
        print("state \(state.count) bytes")
        print("done after \(frames) frames at \(player.currentScript)@\(player.currentPosition)")
    } catch { fail("\(error)") }

case "pic":
    // luca-cli pic <base folder> <image id> <out.png>: as the stage gets it (patches composited).
    guard rest.count >= 3, let id = Int(rest[1]) else { fail("pic <base folder> <id> <out.png>") }
    do {
        let game = try LucaGame(root: URL(fileURLWithPath: rest[0]))
        guard let image = game.image(id), let cg = cgImage(image) else { fail("no picture \(id)") }
        print("\(game.imageName(id) ?? "?") \(image.width)×\(image.height) at \(image.offsetX),\(image.offsetY)")
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: rest[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    } catch { fail("\(error)") }

case "orphans":
    // luca-cli orphans <base folder>: event CGs smaller than the screen that no base covers.
    guard let root = rest.first else { fail("orphans <base folder>") }
    do {
        let game = try LucaGame(root: URL(fileURLWithPath: root))
        for archive in game.images where archive.url.lastPathComponent.uppercased() == "EVENTCG.PAK" {
            for e in archive.entries {
                guard let frame = (try? archive.data(for: e)).flatMap(CZImage.frame(of:)),
                      frame.width < 1900 || frame.height < 1060 else { continue }
                if game.patchBase(of: e, in: archive, area: frame.width * frame.height) == nil {
                    print("\(e.id) \(e.name) \(frame.width)x\(frame.height) at \(frame.x),\(frame.y)")
                }
            }
        }
    } catch { fail("\(error)") }

case "webm":
    // luca-cli webm <file.webm | pak entry: pak name> [out.ogg]
    guard let path = rest.first else { fail("webm <file> | webm <pak> <entry>") }
    do {
        let webm: WebM
        if path.uppercased().hasSuffix(".PAK"), rest.count >= 2 {
            let archive = pak(path)
            guard let entry = archive.entry(named: rest[1]) else { fail("no entry") }
            let (header, file) = try WebM.mvt(archive.data(for: entry))
            print("MVT \(header)")
            webm = file
        } else {
            webm = try WebM(data: Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped))
        }
        for t in webm.tracks { print("track \(t.number) \(t.codec) \(t.width)x\(t.height) \(t.sampleRate)Hz \(t.channels)ch private \(t.codecPrivate.count)") }
        print("\(webm.frames.count) frames, duration \(webm.duration) s")
        for f in webm.frames.prefix(6) { print("  t\(f.track) \(f.time) key=\(f.keyframe) \(f.data.count) bytes") }
        if let out = rest.last, out.hasSuffix(".ogg"), let ogg = webm.vorbisAsOgg() {
            try ogg.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) (\(ogg.count) bytes)")
        }
    } catch { fail("\(error)") }

default:
    fail("unknown command \(command)")
}

/// Composites the stage into a 1920×1080 PNG (no transitions, the text as a caption bar).
func renderStage(_ player: LucaPlayer, to url: URL) {
    let width = 1920, height = 1080
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // CoreGraphics is bottom-up; flip so y grows downward like the game.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    var drawn: [(LucaLayer, Int)] = []
    for layer in player.sortedLayers {
        if let base = layer.baseImageID {
            var whole = layer; whole.imageID = base; whole.baseImageID = nil
            drawn.append((whole, base))
            // The patch then draws at its own offset, as a plain picture would.
            var patch = layer; patch.baseImageID = nil
            drawn.append((patch, -1))
            continue
        }
        drawn.append((layer, 0))
    }
    for (layer, tag) in drawn {
        guard let image = player.game.image(layer.imageID), let cg = cgImage(image) else { continue }
        _ = tag
        let w = Double(image.width) * layer.scale, h = Double(image.height) * layer.scale
        let (x, y) = layer.origin(width: w, height: h, offsetX: Double(image.offsetX), offsetY: Double(image.offsetY))
        ctx.saveGState()
        ctx.setAlpha(layer.alpha)
        if layer.blend == 1 { ctx.setBlendMode(.plusLighter) }
        ctx.translateBy(x: x, y: y + h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }
    if player.windowVisible {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fill(CGRect(x: 0, y: 735, width: 1920, height: 345))
        if let face = player.windowFace, let image = player.game.image(face.imageID), let cg = cgImage(image) {
            let w = Double(image.width), h = Double(image.height)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 735, width: 420, height: 345))
            let rect = player.game.faceRect(face.imageID) ?? (Int(w / 2) - 90, Int(h * 0.12), 180, 150)
            let fx = 215 - (Double(rect.x) + Double(rect.width) / 2), fy = 215 - (Double(rect.y) + Double(rect.height) / 2)
            ctx.translateBy(x: fx, y: 735 + fy + h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        }
    }
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func cgImage(_ image: CZImage) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
    return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}
