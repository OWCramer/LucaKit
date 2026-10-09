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
        for i in s.instructions {
            let fixed = i.fixed.isEmpty ? "" : " \(i.fixed)"
            print("\(i.position)\t\(describe(LucaOp.decode(i)))\(fixed)")
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
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: rest[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    } catch { fail("\(error)") }

default:
    fail("unknown command \(command)")
}
