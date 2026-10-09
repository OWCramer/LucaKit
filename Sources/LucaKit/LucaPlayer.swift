import Foundation

/// One picture on the Luca System stage.
///
/// Layer numbers are `index << 8 | kind`: kind 0 backgrounds, 1 characters, 2 effects and
/// overlays, 7 the face in the text window. `0xFF00 | kind` means every layer of that kind.
/// Positions are in the game's 1920×1080 space: backgrounds and overlays by their top-left
/// corner, characters by their horizontal centre and top.
public struct LucaLayer: Sendable, Equatable, Codable {
    public var number: Int
    public var imageID: Int
    public var x: Double = 0
    public var y: Double = 0
    /// 0…1.
    public var alpha: Double = 1
    public var scale: Double = 1
    /// 0 normal, 1 additive, 2 screen-like (BMODE).
    public var blend: Int = 0
    /// EVSCROLL: the position is a camera offset, the picture's centre from the screen's.
    public var scroll = false
    /// Characters are placed by their centre.
    public var centred: Bool { number & 0xFF == 1 }

    /// Top-left corner on the 1920×1080 screen for a picture of this size (scaled).
    public func origin(width: Double, height: Double, offsetX: Double, offsetY: Double) -> (x: Double, y: Double) {
        if scroll { return (960 - width / 2 + x, 540 - height / 2 + y) }
        if centred { return (x - width / 2, y + offsetY * scale) }
        return (x + offsetX * scale, y + offsetY * scale)
    }

    public var kind: Int { number & 0xFF }
    public var index: Int { number >> 8 }
    /// Drawing order: kind first, then index.
    public var order: Int { kind << 8 | index }
}

/// What the text window shows.
public struct LucaMessage: Sendable, Equatable, Codable {
    public var speaker: String?
    /// Text with the speaker removed and Luca markup turned into plain text (ruby keeps the
    /// base text, colours and sizes are dropped).
    public var text: String
    public var voice: Int
}

/// A sound for the host to play.
public enum LucaSound: Sendable, Equatable {
    case music(id: Int, fadeFrames: Int)
    case stopMusic(fadeFrames: Int)
    case effect(channel: Int, id: Int, loop: Bool, volume: Double, fadeFrames: Int)
    case stopEffect(channel: Int, fadeFrames: Int)
    case voice(id: Int)
    case stopVoice
}

/// Runs a Luca System game's scripts. The host calls `tick()` sixty times a second (the
/// engine counts time in frames), `click()` to read on and `choose(_:)` for choices, and
/// draws `layers`, `message`, `choices` and any running `transition`.
public final class LucaPlayer {
    public let game: LucaGame
    public let table: [String]

    // Stage
    /// The stage as the scripts have built it.
    public private(set) var layers: [Int: LucaLayer] = [:]
    /// The stage as shown: what `layers` was at the last DRAW, with moves and fades applied
    /// live to pictures that are still the same.
    public private(set) var presented: [Int: LucaLayer] = [:]
    /// Music playing (for saves).
    public private(set) var musicID: Int?
    public private(set) var message: LucaMessage?
    public private(set) var windowVisible = false
    public private(set) var choices: [String]?
    /// For each choice shown, its number in the script (options can be hidden).
    private var choiceIndices: [Int] = []
    /// A DRAW in progress: the host crossfades from the stage as it was to the stage now.
    public private(set) var transition: (frames: Int, elapsed: Int)?
    /// Bumped whenever a DRAW starts, so the host knows to snapshot the old stage.
    public private(set) var drawGeneration = 0
    /// Sounds since the host last drained them.
    public var sounds: [LucaSound] = []
    /// Text shown so far, for the backlog.
    public private(set) var backlog: [LucaMessage] = []
    public private(set) var finished = false
    /// Why the player stopped, when it stopped on an error.
    public private(set) var failure: String?
    /// Screen shake offset in game pixels.
    public private(set) var shake: (x: Double, y: Double) = (0, 0)

    // Machine
    public private(set) var variables: [Int: Int] = [:]
    public private(set) var strings: [Int: String] = [:]
    private struct Frame { var script: LucaScript; var index: Int }
    private var frame: Frame
    private var callStack: [Frame] = []

    private enum Wait {
        case none
        case frames(Int)
        case click
        case choice(variable: Int)
        case transition
    }
    private var wait: Wait = .none

    private struct Tween {
        var layer: Int
        var from: (x: Double, y: Double, alpha: Double, scale: Double)
        var to: (x: Double?, y: Double?, alpha: Double?, scale: Double?)
        var frames: Int
        var elapsed = 0
        var easing: Int
    }
    private var tweens: [Tween] = []
    private var quake: (frames: Int, elapsed: Int, amplitude: Double)?

    public init(game: LucaGame, script: String = "00_シナリオフロー", table: [String] = LucaOpcodes.reflectionBlue) throws {
        self.game = game
        self.table = table
        frame = Frame(script: try game.script(named: script), index: 0)
    }

    public var currentScript: String { frame.script.name }
    public var currentPosition: Int {
        frame.index < frame.script.instructions.count ? frame.script.instructions[frame.index].position : -1
    }

    public var sortedLayers: [LucaLayer] { presented.values.sorted { $0.order < $1.order } }

    public var isWaitingForClick: Bool {
        if case .click = wait { return true }
        return false
    }

    // MARK: Host input

    /// One 1/60 s step: animations advance, waits count down, scripts run until they block.
    public func tick() {
        guard !finished else { return }
        advanceAnimations()
        switch wait {
        case .frames(let n):
            wait = n > 1 ? .frames(n - 1) : .none
        case .transition:
            if transition == nil && tweens.isEmpty { wait = .none }
        default:
            break
        }
        run()
    }

    /// A tap: finishes the transition in progress, or reads on.
    public func click() {
        if case .click = wait {
            wait = .none
            sounds.append(.stopVoice)
            run()
        } else if transition != nil {
            transition = nil
        }
    }

    public func choose(_ index: Int) {
        guard case .choice(let variable) = wait else { return }
        variables[variable] = choiceIndices.indices.contains(index) ? choiceIndices[index] : index
        choices = nil
        wait = .none
        run()
    }

    /// Skips ahead: transitions and animations finish at once.
    public func finishAnimations() {
        transition = nil
        for tween in tweens { apply(tween, progress: 1) }
        tweens.removeAll()
    }

    // MARK: Machine

    private func run() {
        var budget = 20_000
        while !finished, case .none = wait {
            budget -= 1
            if budget == 0 { return } // a long run of logic: continue next frame
            guard frame.index < frame.script.instructions.count else {
                if !returnFromCall() { finish() }
                continue
            }
            let instruction = frame.script.instructions[frame.index]
            frame.index += 1
            execute(instruction)
        }
    }

    private func finish(_ why: String? = nil) {
        finished = true
        failure = why
    }

    @discardableResult
    private func returnFromCall() -> Bool {
        guard let caller = callStack.popLast() else { return false }
        frame = caller
        return true
    }

    private func jump(to position: Int) {
        if let index = frame.script.index(atPosition: position) {
            frame.index = index
        } else {
            finish("\(frame.script.name): no instruction at \(position)")
        }
    }

    private func enter(script name: String, at position: Int?) -> Bool {
        do {
            let script = try game.script(named: name)
            frame = Frame(script: script, index: 0)
            if let position, position > 0 { jump(to: position) }
            return true
        } catch {
            finish("\(error)")
            return false
        }
    }

    func value(_ variable: Int) -> Int { variables[variable] ?? 0 }

    private func evaluate(_ text: String) -> Int {
        LucaExpression.evaluate(text, variables: { [unowned self] in value($0) })
    }

    private func execute(_ instruction: LucaScript.Instruction) {
        let op = LucaOp.decode(instruction, table: table)
        switch op {
        case .branch(let ifTrue, let expression, let target):
            if (evaluate(expression) != 0) == ifTrue { jump(to: target) }
        case .goto(let target):
            jump(to: target)
        case .gosub(_, let target):
            callStack.append(frame)
            jump(to: target)
        case .jump(let script, let target):
            _ = enter(script: script, at: target)
        case .farcall(_, let script, let target):
            callStack.append(frame)
            _ = enter(script: script, at: target)
        case .message(let voice, let japanese, let english, _, _):
            let raw = english.isEmpty ? japanese : english
            if raw.isEmpty { break } // an empty MESSAGE ends a voiced pause
            let parsed = Self.parse(raw, strings: strings)
            message = LucaMessage(speaker: parsed.speaker, text: parsed.text, voice: Int(voice))
            windowVisible = true
            backlog.append(message!)
            if backlog.count > 300 { backlog.removeFirst() }
            if voice > 0 { sounds.append(.voice(id: Int(voice))) }
            wait = .click
        case .select(let values, let japanese, let english, _, _):
            let raw = english.isEmpty ? japanese : english
            // `[(expr),]Text` shows that option only while expr is nonzero (options already
            // tried drop out of a choice the script loops back to).
            var shown: [String] = []
            var indices: [Int] = []
            for (index, option) in raw.components(separatedBy: "$d").enumerated() {
                var text = option
                if text.hasPrefix("[("), let close = text.range(of: ")") {
                    let condition = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
                    if let end = text.range(of: "]", range: close.upperBound..<text.endIndex) {
                        text = String(text[end.upperBound...])
                    }
                    if evaluate(condition) == 0 { continue }
                }
                shown.append(Self.parse(text, strings: strings).text)
                indices.append(index)
            }
            choices = shown
            choiceIndices = indices
            wait = .choice(variable: Int(values[0]))
        case .varstrSet(_, let variable, let japanese, let english, _):
            strings[Int(variable)] = english.isEmpty ? japanese : english
        case .logBegin, .dialog, .movie:
            break
        case .expression:
            break
        case .raw(let name, let values, let tail):
            executeRaw(name, values, tail: tail, instruction)
        }
    }

    private func executeRaw(_ name: String, _ v: [UInt16], tail: UInt8?, _ instruction: LucaScript.Instruction) {
        var r = ParamReader(instruction.params)
        switch name {
        case "EQUN":
            variables[Int(r.u16())] = Int(Int16(bitPattern: r.u16()))
        case "EQU":
            let variable = Int(r.u16())
            let marker = r.u16()
            if marker == 0x7FFE {
                variables[variable] = Int(Int16(bitPattern: r.u16()))
            } else {
                // A length-prefixed UTF-8 expression; rewind and read it whole.
                var s = ParamReader(instruction.params)
                _ = s.u16()
                variables[variable] = evaluate(s.lstrUTF8())
            }
        case "ADD", "SUB", "MUL", "DIV", "MOD", "AND", "OR":
            let variable = Int(r.u16())
            let marker = r.u16()
            let operand: Int
            if marker == 0x7FFE {
                operand = Int(Int16(bitPattern: r.u16()))
            } else {
                var s = ParamReader(instruction.params)
                _ = s.u16()
                operand = evaluate(s.lstrUTF8())
            }
            let old = value(variable)
            switch name {
            case "ADD": variables[variable] = old &+ operand
            case "SUB": variables[variable] = old &- operand
            case "MUL": variables[variable] = old &* operand
            case "DIV": variables[variable] = operand == 0 ? 0 : old / operand
            case "MOD": variables[variable] = operand == 0 ? 0 : old % operand
            case "AND": variables[variable] = old & operand
            default: variables[variable] = old | operand
            }
        case "RANDOM":
            let variable = Int(r.u16())
            let range = max(1, Int(r.u16()))
            variables[variable] = Int.random(in: 0..<range)
        case "RETURN", "FARRETURN":
            if !returnFromCall() { finish() }
        case "END":
            if !returnFromCall() { finish() }

        case "IMAGELOAD":
            let number = Int(r.u16())
            let id = Int(r.u16())
            var layer = layers[number] ?? LucaLayer(number: number, imageID: id)
            layer.imageID = id
            if instruction.params.count >= 14 {
                _ = r.u16() // mode
                layer.x = Double(Float(bitPattern: r.u32()))
                layer.y = Double(Float(bitPattern: r.u32()))
                layer.alpha = 1
                layer.scale = 1
                layer.scroll = false
                // A new picture with a position starts afresh: earlier moves stop.
                tweens.removeAll { $0.layer == number }
            }
            layers[number] = layer
        case "IMAGEUPDATE":
            let number = Int(r.u16())
            let id = Int(r.u16())
            if var layer = layers[number] {
                layer.imageID = id
                layers[number] = layer
            }
        case "INIT":
            let number = Int(r.u16())
            remove(number)
        case "MOVE":
            let number = Int(r.u16())
            _ = r.u8()
            let mode = Int(r.u16())
            let frames = Int(r.u16())
            let x = r.remaining >= 4 ? Double(Float(bitPattern: r.u32())) : nil
            let y = r.remaining >= 4 ? Double(Float(bitPattern: r.u32())) : nil
            animate(number, x: x, y: y, frames: frames, easing: mode)
        case "FADE":
            let number = Int(r.u16())
            let alpha = Double(r.u8()) / 255
            let frames = r.remaining >= 2 ? Int(r.u16()) : 0
            forEachLayer(number) { animate($0, alpha: alpha, frames: frames, easing: 0) }
        case "SCALE":
            let number = Int(r.u16())
            if instruction.params.count < 12 {
                forEachLayer(number) { animate($0, scale: 1, frames: 0, easing: 0) }
            } else {
                let frames = Int(r.u16())
                let scale = Double(Float(bitPattern: r.u32()))
                if scale.isFinite, scale > 0.01, scale < 20 {
                    forEachLayer(number) { animate($0, scale: scale, frames: frames, easing: 0x20) }
                }
            }
        case "EVSCROLL":
            let number = Int(r.u16())
            forEachLayer(number) { layers[$0]?.scroll = true }
        case "BMODE":
            let number = Int(r.u16())
            let mode = Int(r.u8())
            forEachLayer(number) { layers[$0]?.blend = mode }
        case "DRAW":
            let frames = v.first.map(Int.init) ?? 0
            drawGeneration += 1
            presented = layers
            transition = frames > 0 ? (frames, 0) : nil
        case "WAIT":
            if let frames = v.first.map(Int.init), frames > 0 {
                wait = .frames(frames)
            } else {
                wait = .transition
            }
        case "WAIT_TIME", "WAIT_COUNT":
            if let frames = v.first.map(Int.init), frames > 0 { wait = .frames(frames) }
        case "MESSAGE_CLEAR":
            message = nil
        case "CLOSE_WINDOW":
            windowVisible = false
            message = nil
        case "QUAKE":
            quake = (frames: 40, elapsed: 0, amplitude: 12)

        case "BGM":
            let id = Int(r.u32())
            if id == 0 {
                musicID = nil
                sounds.append(.stopMusic(fadeFrames: r.remaining >= 2 ? Int(r.u16()) : 0))
            } else if instruction.params.count >= 4 {
                musicID = id
                sounds.append(.music(id: id, fadeFrames: 0))
            } else {
                musicID = nil
                sounds.append(.stopMusic(fadeFrames: 0))
            }
        case "SE":
            let channel = Int(r.u8())
            guard instruction.params.count >= 5 else {
                sounds.append(.stopEffect(channel: channel, fadeFrames: 0))
                break
            }
            let id = Int(r.u32())
            if id == 0 {
                sounds.append(.stopEffect(channel: channel, fadeFrames: r.remaining >= 2 ? Int(r.u16()) : 0))
            } else {
                let loopFlag = r.remaining >= 1 ? r.u8() : 0
                sounds.append(.effect(channel: channel, id: id, loop: loopFlag != 0, volume: 1, fadeFrames: 0))
            }
        case "SE_STOP":
            sounds.append(.stopEffect(channel: Int(r.u8()), fadeFrames: 0))
        case "VOICE_STOP":
            sounds.append(.stopVoice)

        default:
            break // not drawn or not needed yet (TASK, SETCGFLAG, SCALE, EVSCROLL, …)
        }
    }

    // MARK: Layers and animation

    private func forEachLayer(_ number: Int, _ body: (Int) -> Void) {
        if number >> 8 == 0xFF {
            for n in layers.keys where n & 0xFF == number & 0xFF { body(n) }
        } else if layers[number] != nil {
            body(number)
        }
    }

    private func remove(_ number: Int) {
        if number >> 8 == 0xFF {
            layers = layers.filter { $0.key & 0xFF != number & 0xFF }
            tweens.removeAll { $0.layer & 0xFF == number & 0xFF }
        } else {
            layers.removeValue(forKey: number)
            tweens.removeAll { $0.layer == number }
        }
    }

    private func animate(_ number: Int, x: Double? = nil, y: Double? = nil, alpha: Double? = nil,
                         scale: Double? = nil, frames: Int, easing: Int) {
        guard let layer = layers[number] else { return }
        let tween = Tween(layer: number, from: (layer.x, layer.y, layer.alpha, layer.scale),
                          to: (x, y, alpha, scale), frames: frames, easing: easing)
        // A new move replaces the running move, a fade the fade, a zoom the zoom.
        func kind(_ to: (x: Double?, y: Double?, alpha: Double?, scale: Double?)) -> Int {
            to.x != nil || to.y != nil ? 0 : (to.alpha != nil ? 1 : 2)
        }
        let newKind = kind(tween.to)
        tweens.removeAll { $0.layer == number && kind($0.to) == newKind }
        if frames <= 0 {
            apply(tween, progress: 1)
        } else {
            tweens.append(tween)
        }
    }

    private func apply(_ tween: Tween, progress: Double) {
        guard var layer = layers[tween.layer] else { return }
        let t: Double
        switch tween.easing & 0x60 {
        case 0x20: t = progress * progress * (3 - 2 * progress) // ease in and out
        case 0x40: t = 1 - (1 - progress) * (1 - progress)      // ease out
        default: t = progress
        }
        if let x = tween.to.x { layer.x = tween.from.x + (x - tween.from.x) * t }
        if let y = tween.to.y { layer.y = tween.from.y + (y - tween.from.y) * t }
        if let a = tween.to.alpha { layer.alpha = tween.from.alpha + (a - tween.from.alpha) * t }
        if let s = tween.to.scale { layer.scale = tween.from.scale + (s - tween.from.scale) * t }
        layers[tween.layer] = layer
    }

    private func advanceAnimations() {
        if var t = transition {
            t.elapsed += 1
            transition = t.elapsed >= t.frames ? nil : t
        }
        var running: [Tween] = []
        for var tween in tweens {
            tween.elapsed += 1
            let progress = min(1, Double(tween.elapsed) / Double(max(1, tween.frames)))
            apply(tween, progress: progress)
            if progress < 1 { running.append(tween) }
        }
        tweens = running
        for (number, shown) in presented {
            if let current = layers[number], current.imageID == shown.imageID { presented[number] = current }
        }
        if var q = quake {
            q.elapsed += 1
            let fade = 1 - Double(q.elapsed) / Double(q.frames)
            shake = q.elapsed >= q.frames ? (0, 0)
                : (Double.random(in: -1...1) * q.amplitude * fade, Double.random(in: -1...1) * q.amplitude * fade)
            quake = q.elapsed >= q.frames ? nil : q
        }
    }

    /// Pictures the script will load soon (from here, not following jumps), so the host can
    /// decode them ahead of time.
    public func upcomingImages(lookahead: Int = 80) -> [Int] {
        var ids: [Int] = []
        let instructions = frame.script.instructions
        var i = frame.index
        while i < instructions.count, i < frame.index + lookahead {
            let instruction = instructions[i]
            let name = LucaOpcodes.name(instruction.opcode, table: table)
            if (name == "IMAGELOAD" || name == "IMAGEUPDATE"), instruction.params.count >= 4 {
                ids.append(Int(UInt16(instruction.params[2]) | UInt16(instruction.params[3]) << 8))
            }
            i += 1
        }
        return ids
    }

    // MARK: Saves

    /// Everything needed to carry on from here. Saved while waiting for a click (or a
    /// choice): the scripts resume there.
    public struct State: Codable, Sendable {
        public struct Position: Codable, Sendable {
            public var script: String
            public var index: Int
        }
        public var version = 1
        public var position: Position
        public var callStack: [Position]
        public var variables: [Int: Int]
        public var strings: [Int: String]
        public var layers: [Int: LucaLayer]
        public var presented: [Int: LucaLayer]
        public var windowVisible: Bool
        public var message: LucaMessage?
        public var choices: [String]?
        public var choiceVariable: Int?
        public var choiceIndices: [Int]?
        public var musicID: Int?
        public var backlog: [LucaMessage]
    }

    public func saveState() -> State {
        var choiceVariable: Int?
        if case .choice(let variable) = wait {
            choiceVariable = variable
        }
        return State(position: .init(script: frame.script.name, index: frame.index),
                     callStack: callStack.map { .init(script: $0.script.name, index: $0.index) },
                     variables: variables, strings: strings, layers: layers, presented: presented,
                     windowVisible: windowVisible, message: message, choices: choices,
                     choiceVariable: choiceVariable, choiceIndices: choiceIndices, musicID: musicID, backlog: Array(backlog.suffix(100)))
    }

    /// Resumes a saved game: the stage as it was, the music again, and the same line waiting
    /// for a click (or the same choice).
    public func restore(_ state: State) throws {
        frame = Frame(script: try game.script(named: state.position.script), index: state.position.index)
        callStack = try state.callStack.map { Frame(script: try game.script(named: $0.script), index: $0.index) }
        variables = state.variables
        strings = state.strings
        layers = state.layers
        presented = state.presented
        windowVisible = state.windowVisible
        message = state.message
        choices = state.choices
        choiceIndices = state.choiceIndices ?? Array(0..<(state.choices?.count ?? 0))
        backlog = state.backlog
        tweens.removeAll()
        transition = nil
        drawGeneration += 1
        finished = false
        failure = nil
        musicID = state.musicID
        sounds = [.stopVoice, .stopEffect(channel: -1, fadeFrames: 0)]
        sounds.append(state.musicID.map { .music(id: $0, fadeFrames: 30) } ?? .stopMusic(fadeFrames: 0))
        if let variable = state.choiceVariable, state.choices != nil {
            wait = .choice(variable: variable)
        } else if state.message != nil {
            wait = .click
        } else {
            wait = .none
        }
    }

    // MARK: Text

    /// Splits `@Name@` off the front and turns Luca markup into plain text.
    public static func parse(_ raw: String, strings: [Int: String]) -> (speaker: String?, text: String) {
        var text = raw
        var speaker: String?
        if text.hasPrefix("@"), let end = text.dropFirst().firstIndex(of: "@") {
            speaker = expand(String(text[text.index(after: text.startIndex)..<end]), strings: strings)
            text = String(text[text.index(after: end)...])
        }
        // A second speaker's line after `$d$w` is spoken at the same time; show the first.
        if let dual = text.range(of: "$d$w") { text = String(text[..<dual.lowerBound]) }
        return (speaker, expand(text, strings: strings))
    }

    static func expand(_ s: String, strings: [Int: String]) -> String {
        var out = ""
        var chars = Array(s)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            guard c == "$", let code = chars.first else {
                switch c {
                case "❝", "❞": out.append("\"")
                case "❛", "❜": out.append("'")
                case "﹣": out.append("-")
                default: out.append(c)
                }
                continue
            }
            chars = chars.dropFirst()
            switch code {
            case "[":
                // $[base$/ruby$]: keep the base.
                var base = ""
                while let d = chars.first, d != "$" { base.append(d); chars = chars.dropFirst() }
                out += base
                while !chars.isEmpty, !(chars.first == "$" && chars.dropFirst().first == "]") { chars = chars.dropFirst() }
                chars = chars.dropFirst(2)
            case "]", "/":
                break
            case "C":
                // $C[rrggbb] … $C[]
                if chars.first == "[", let close = chars.firstIndex(of: "]") { chars = chars[(close + 1)...] }
            case "S":
                chars = chars.dropFirst(3) // $S056
            case "(":
                var digits = ""
                while let d = chars.first, d != ")" { digits.append(d); chars = chars.dropFirst() }
                chars = chars.dropFirst()
                if let n = Int(digits) { out += strings[n] ?? "" }
            case "d":
                out.append("\n")
            case "n":
                out.append("\n")
            default:
                break
            }
        }
        return out
    }
}
