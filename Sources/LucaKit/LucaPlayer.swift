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
    /// The whole picture a smaller one (an expression patch, an inset) is drawn over: the
    /// last whole picture loaded onto this layer, as the PC engine does.
    public var baseImageID: Int?
    /// Characters (1) and close-up character overlays (3) are placed by their centre.
    public var centred: Bool { kind == 1 || kind == 3 }

    /// Top-left corner on the 1920×1080 screen for a picture of this size (scaled).
    public func origin(width: Double, height: Double, offsetX: Double, offsetY: Double) -> (x: Double, y: Double) {
        if centred { return (x - width / 2, y + offsetY * scale) }
        var origin = scroll ? (x: 960 - width / 2 + x, y: 540 - height / 2 + y)
                            : (x: x + offsetX * scale, y: y + offsetY * scale)
        // A background at least as big as the screen never shows past its edge: pans whose
        // coordinates Shiori reads differently from the PC engine stop at the picture's edge
        // instead of showing black.
        if kind == 0 {
            if width >= 1920 { origin.x = min(0, max(1920 - width, origin.x)) }
            if height >= 1080 { origin.y = min(0, max(1080 - height, origin.y)) }
        }
        return origin
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
    /// A `LOG_BEGIN` line: narration the PC game shows in its own box (Harmonia's NWIN)
    /// rather than the message window. Absent in saves made before it was recorded.
    public var narration: Bool?
}

/// Colour effects over the whole stage.
public struct LucaStageEffects: Sendable, Equatable, Codable {
    /// 0…1.
    public var sepia: Float = 0
    public init() {}
}

/// A card the host shows over the story for a moment.
public enum LucaNotice: Sendable, Equatable {
    /// The day, as "July 26".
    case date(String)
    /// An item or title acquired.
    case acquired(String)
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
    /// A heading for the choices, when they aren't the script's own (the map).
    public private(set) var choicePrompt: String?
    /// A line under each choice, when the choices are places on the map.
    public private(set) var choiceDetails: [String?] = []
    /// For each choice shown, its number in the script (options can be hidden).
    private var choiceIndices: [Int] = []
    /// A DRAW in progress: the host crossfades from the stage as it was to the stage now.
    public private(set) var transition: (frames: Int, elapsed: Int)?
    /// Bumped whenever a DRAW starts, so the host knows to snapshot the old stage.
    public private(set) var drawGeneration = 0
    /// Sounds since the host last drained them.
    public var sounds: [LucaSound] = []
    /// Whole-stage colour effects (SEPIA, TONE, ADDCOLOR) for the host's renderer.
    public private(set) var effects = LucaStageEffects()
    /// Things the PC executable shows over the story (the day's date, items acquired), for
    /// the host to show briefly; drained by the host.
    public var notices: [LucaNotice] = []
    /// A movie (`files/movie/<name>.webm`) the host should play now; the script waits until
    /// the host calls `movieFinished()`.
    public private(set) var movie: String?
    /// Text shown so far, for the backlog.
    public private(set) var backlog: [LucaMessage] = []
    /// Where the line on screen is in the scripts (stable across runs), for the host's record
    /// of lines already read.
    public private(set) var messageKey: UInt64?
    /// Options: a tap that reads on stops the line's voice (else it plays until the next one).
    public var stopsVoiceOnClick = true
    /// The state at each recent line, for rewinding and resuming from the Message Log. The
    /// backlog is left out of these; `serial` numbers the line among all lines shown.
    public private(set) var history: [(serial: Int, state: State)] = []
    public var historyLimit = 200
    /// Lines shown so far (the newest line's serial).
    public private(set) var lineSerial = 0
    /// The serial of `backlog[i]`.
    public func serial(ofBacklogLine index: Int) -> Int { lineSerial - backlog.count + index + 1 }
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
        case movie
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

    public init(game: LucaGame, script: String? = nil, table: [String] = LucaOpcodes.reflectionBlue) throws {
        self.game = game
        self.table = table
        frame = Frame(script: try game.script(named: script ?? game.entryScript), index: 0)
    }

    public var currentScript: String { frame.script.name }
    public var currentPosition: Int {
        frame.index < frame.script.instructions.count ? frame.script.instructions[frame.index].position : -1
    }

    /// What to draw on the stage, in order. The face in the text window (kind 7) is
    /// `windowFace`.
    public var sortedLayers: [LucaLayer] { presented.values.filter { $0.kind != 7 }.sorted { $0.order < $1.order } }

    /// The speaker's face shown at the left of the text window: the whole sprite, its centre
    /// at `x` and its top at `y` relative to the window, clipped by the window.
    /// It belongs to the next line only: the script loads it just before each line that has one.
    public var windowFace: LucaLayer? { layers.values.first { $0.kind == 7 } }
    private var faceLoadedForLine = false

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
            // A bare WAIT waits for the DRAW only: long camera pans (35–55 s) carry on under
            // the story.
            if transition == nil { wait = .none }
        default:
            break
        }
        run()
    }

    /// A tap: finishes the transition in progress, or reads on.
    public func click() {
        if case .click = wait {
            wait = .none
            if stopsVoiceOnClick { sounds.append(.stopVoice) }
            run()
        } else if transition != nil {
            transition = nil
        } else if case .frames = wait {
            // A tap cuts a pause short, as on PC.
            wait = .none
            run()
        }
    }

    public func choose(_ index: Int) {
        guard case .choice(let variable) = wait else { return }
        variables[variable] = choiceIndices.indices.contains(index) ? choiceIndices[index] : index
        choices = nil
        choicePrompt = nil
        wait = .none
        run()
    }

    /// The movie ended (or was skipped).
    public func movieFinished() {
        guard case .movie = wait else { return }
        movie = nil
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

    /// FNV-1a over the script's name and the line's byte position.
    /// The read-log key of every line (MESSAGE and LOG_BEGIN) in a script, for telling whether
    /// any of it has been read.
    public static func lineKeys(in script: LucaScript) -> [UInt64] {
        script.instructions.compactMap { instruction in
            let name = LucaOpcodes.name(instruction.opcode)
            return name == "MESSAGE" || name == "LOG_BEGIN" ? key(script.name, instruction.position) : nil
        }
    }

    static func key(_ script: String, _ position: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(script.utf8) + withUnsafeBytes(of: Int64(position).littleEndian, Array.init) {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// A line of text: shown in the window, kept in the backlog and history, waited on.
    private func showLine(voice: Int, japanese: String, english: String, narration: Bool = false) {
        let raw = english.isEmpty ? japanese : english
        if raw.isEmpty { return } // an empty MESSAGE ends a voiced pause
        let parsed = Self.parse(raw, strings: strings)
        if !faceLoadedForLine { layers = layers.filter { $0.value.kind != 7 } }
        faceLoadedForLine = false
        message = LucaMessage(speaker: parsed.speaker, text: parsed.text, voice: voice, narration: narration ? true : nil)
        messageKey = Self.key(frame.script.name, frame.script.instructions[frame.index - 1].position)
        windowVisible = true
        backlog.append(message!)
        if backlog.count > 500 { backlog.removeFirst() }
        if voice > 0 { sounds.append(.voice(id: voice)) }
        wait = .click
        lineSerial += 1
        history.append((lineSerial, saveState(withBacklog: false)))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    /// Scripts place pictures on the screen size they declare at startup (`EQUN 30001`):
    /// 1920 wide in REFLECTION BLUE, 1280 in Harmonia Full HD, whose art is 1920 wide anyway.
    private var coordinateScale: Double {
        let declared = variables[30001] ?? 1920
        return declared > 0 ? 1920 / Double(declared) : 1
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
            showLine(voice: Int(voice), japanese: japanese, english: english)
        case .logBegin(_, _, let japanese, let english, _):
            // Narration over the stage (Harmonia's opening): a line without a speaker, waited
            // on like any other.
            showLine(voice: 0, japanese: japanese, english: english, narration: true)
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
            choiceDetails = []
            choicePrompt = nil
            wait = .choice(variable: Int(values[0]))
        case .varstrSet(_, let variable, let japanese, let english, _):
            strings[Int(variable)] = english.isEmpty ? japanese : english
        case .movie(let file, _):
            movie = file
            wait = .movie
        case .dialog:
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
            if number & 0xFF == 7 { faceLoadedForLine = true }
            var layer = layers[number] ?? LucaLayer(number: number, imageID: id)
            setPicture(&layer, id)
            if instruction.params.count >= 14 {
                _ = r.u16() // mode
                layer.x = Double(Float(bitPattern: r.u32())) * coordinateScale
                layer.y = Double(Float(bitPattern: r.u32())) * coordinateScale
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
                setPicture(&layer, id)
                layers[number] = layer
                if number & 0xFF == 7 { faceLoadedForLine = true }
            }
        case "INIT":
            let number = Int(r.u16())
            remove(number)
        case "MOVE":
            let number = Int(r.u16())
            _ = r.u8()
            let mode = Int(r.u16())
            let frames = Int(r.u16())
            let x = r.remaining >= 4 ? Double(Float(bitPattern: r.u32())) * coordinateScale : nil
            let y = r.remaining >= 4 ? Double(Float(bitPattern: r.u32())) * coordinateScale : nil
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
        case "SEPIA":
            // SEPIA target, mode, 255 on / 0 off.
            if instruction.params.count >= 3 { effects.sepia = Float(instruction.params[2]) / 255 }
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
            // Channel 255 is every channel.
            let channel = { $0 == 255 ? -1 : $0 }(Int(r.u8()))
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
        case "TASK":
            switch r.u16() {
            case 53:
                // The day's map: the PC game draws it in its executable and writes the place
                // picked into a variable. Shiori offers the places the script goes on to test.
                let variable = Int(r.u16())
                offerMap(variable: variable)
            case 3:
                // The day card: "0726".
                let day = r.lstrUTF8()
                if day.count == 4, let month = Int(day.prefix(2)), let date = Int(day.suffix(2)),
                   (1...12).contains(month) {
                    let name = DateFormatter().monthSymbols[month - 1]
                    notices.append(.date("\(name) \(date)"))
                }
            case 8:
                // "Acquired …": Japanese, then English.
                _ = r.lstrUTF16()
                _ = r.u16()
                _ = r.u16()
                let english = r.lstrUTF16()
                if !english.isEmpty { notices.append(.acquired(Self.expand(english, strings: strings))) }
            default:
                break
            }
        case "SE_STOP":
            sounds.append(.stopEffect(channel: Int(r.u8()), fadeFrames: 0))
        case "VOICE_STOP":
            sounds.append(.stopVoice)

        default:
            break // not drawn or not needed yet (TASK, SETCGFLAG, SCALE, EVSCROLL, …)
        }
    }

    // MARK: The map

    /// After the map TASK the script tests the variable place by place (`IFN ((#6049)==4)`),
    /// each test guarding a call into that place's scene. Every place with a scene becomes a
    /// choice, named after the scene it leads to.
    private func offerMap(variable: Int) {
        let instructions = frame.script.instructions
        var options: [(value: Int, place: Place)] = []
        var i = frame.index
        let pattern = try? Regex<(Substring, Substring, Substring)>(#"^\(*#(\d+)\)*==(\d+)\)*$"#)
        while i < instructions.count, i < frame.index + 600 {
            let op = LucaOp.decode(instructions[i], table: table)
            if case .raw(let name, let values, _) = op, name == "TASK", values.first == 53 { break }
            if case .branch(false, let expression, let target) = op,
               let pattern, let match = expression.wholeMatch(of: pattern),
               Int(match.output.1) == variable, let value = Int(match.output.2),
               !options.contains(where: { $0.value == value }),
               let end = frame.script.index(atPosition: target),
               let place = destination(in: frame.script, from: i + 1, to: end),
               !Self.minigames.contains(place.label),
               !options.contains(where: { $0.place.script == place.script && $0.place.position == place.position }) {
                options.append((value, place))
            }
            i += 1
        }
        guard !options.isEmpty else { return }
        choices = options.map(\.place.label)
        choiceDetails = options.map(\.place.detail)
        choiceIndices = options.map(\.value)
        choicePrompt = "Where will you go?"
        wait = .choice(variable: variable)
    }

    private struct Place {
        var script: String
        var position: Int
        var label: String
        /// The scene's first line of narration: usually where Hairi goes ("I arrive at the shrine.").
        var detail: String?
    }

    /// The first scene called between two instructions (following a call back into the same
    /// script one step).
    private func destination(in script: LucaScript, from start: Int, to end: Int, depth: Int = 0) -> Place? {
        var i = start
        while i < min(end, script.instructions.count) {
            var call: (name: String, target: Int?)?
            switch LucaOp.decode(script.instructions[i], table: table) {
            case .farcall(_, let name, let target): call = (name, target)
            case .jump(let name, let target): call = (name, target)
            default: break
            }
            if let call {
                if call.name != script.name {
                    return Place(script: call.name, position: call.target ?? 0, label: Self.placeName(call.name),
                                 detail: firstLine(of: call.name, at: call.target ?? 0))
                }
                if depth == 0, let target = call.target, let index = script.index(atPosition: target) {
                    return destination(in: script, from: index, to: index + 60, depth: 1)
                }
            }
            i += 1
        }
        return nil
    }

    /// The first narrated line (no speaker) a scene shows.
    private func firstLine(of name: String, at position: Int) -> String? {
        guard let script = try? game.script(named: name) else { return nil }
        var i = script.index(atPosition: position) ?? 0
        let end = min(script.instructions.count, i + 400)
        while i < end {
            if case .message(_, let japanese, let english, _, _) = LucaOp.decode(script.instructions[i], table: table) {
                let raw = english.isEmpty ? japanese : english
                let parsed = Self.parse(raw, strings: strings)
                if parsed.speaker == nil, !parsed.text.isEmpty { return parsed.text }
            }
            i += 1
        }
        return nil
    }

    /// Places that start a minigame the executable runs (Shiori can't yet).
    static let minigames: Set<String> = ["Islamon", "Ping-Pong"]

    /// `20_しろは0729AM` → Shiroha, `RB30_識_0729` → Shiki, `80_駄菓子屋0729` → Candy Store.
    static func placeName(_ script: String) -> String {
        let names: [(String, String)] = [
            ("しろは", "Shiroha"), ("蒼", "Ao"), ("鴎", "Kamome"), ("紬", "Tsumugi"), ("うみ", "Umi"),
            ("識", "Shiki"), ("美希", "Miki"), ("静久", "Shizuku"), ("駄菓子屋", "Candy Store"),
            ("秘密基地", "Secret Base"), ("神社", "Shrine"), ("卓球", "Ping-Pong"), ("島モン", "Islamon"),
            ("島キング", "Island King"), ("食堂", "Cafeteria"), ("日常", "Around the Island"),
            ("突然のコイ", "A Sudden Koi"),
        ]
        return names.first { script.contains($0.0) }?.1 ?? script
    }

    // MARK: Layers and animation

    /// A whole picture replaces the layer's; a smaller one (event CG expressions, insets) is
    /// drawn over the layer's last whole picture. Characters compose by name (LucaGame).
    private func setPicture(_ layer: inout LucaLayer, _ id: Int) {
        let previousBase = layer.baseImageID ?? layer.imageID
        layer.imageID = id
        guard layer.kind == 0 || layer.kind == 2, let frame = game.frame(id) else { layer.baseImageID = nil; return }
        let whole = frame.x == 0 && frame.y == 0 && frame.width >= 1920 && frame.height >= 1080
        // Patches with a base by name (cg_sz01_0203 on cg_sz01_0201) are composed by LucaGame.
        if whole || previousBase == id || game.hasNamedBase(id) {
            layer.baseImageID = nil
        } else if let base = game.frame(previousBase), base.x == 0, base.y == 0, base.width >= 1920, base.height >= 1080 {
            layer.baseImageID = previousBase
        } else {
            layer.baseImageID = nil
        }
    }

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
        public var choicePrompt: String?
        public var choiceDetails: [String?]?
        public var musicID: Int?
        public var effects: LucaStageEffects?
        public var backlog: [LucaMessage]
    }

    public func saveState() -> State { saveState(withBacklog: true) }

    private func saveState(withBacklog: Bool) -> State {
        var choiceVariable: Int?
        if case .choice(let variable) = wait {
            choiceVariable = variable
        }
        // Layers still moving are recorded where they're headed (a restore doesn't resume
        // animations): a long camera pan would otherwise come back half done.
        let now = layers
        for tween in tweens { apply(tween, progress: 1) }
        let layers = self.layers
        self.layers = now
        var presented = self.presented
        for (number, shown) in presented {
            if let layer = layers[number], layer.imageID == shown.imageID { presented[number] = layer }
        }
        return State(position: .init(script: frame.script.name, index: frame.index),
                     callStack: callStack.map { .init(script: $0.script.name, index: $0.index) },
                     variables: variables, strings: strings, layers: layers, presented: presented,
                     windowVisible: windowVisible, message: message, choices: choices,
                     choiceVariable: choiceVariable, choiceIndices: choiceIndices, choicePrompt: choicePrompt, choiceDetails: choiceDetails, musicID: musicID, effects: effects,
                     backlog: withBacklog ? Array(backlog.suffix(500)) : [])
    }

    /// Resumes a saved game: the stage as it was, the music again, and the same line waiting
    /// for a click (or the same choice).
    /// Whether line `serial` can be returned to.
    public func canReturn(to serial: Int) -> Bool { history.contains { $0.serial == serial } }

    /// Goes back to line `serial` as it was first shown: the stage, variables and music then,
    /// the log cut back to it, and its voice again.
    public func returnTo(line serial: Int) throws {
        guard let entry = history.firstIndex(where: { $0.serial == serial }) else { return }
        let kept = Array(backlog.prefix(max(0, backlog.count - (lineSerial - serial))))
        let keptHistory = Array(history.prefix(entry + 1))
        try restore(history[entry].state)
        backlog = kept
        history = keptHistory
        lineSerial = serial
        if let voice = message?.voice, voice > 0 { sounds.append(.voice(id: voice)) }
    }

    /// One line back (nil when there's no earlier line to return to).
    public var previousLine: Int? {
        history.count >= 2 ? history[history.count - 2].serial : nil
    }

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
        choicePrompt = state.choicePrompt
        choiceDetails = state.choiceDetails ?? []
        backlog = state.backlog
        lineSerial = backlog.count
        history = []
        tweens.removeAll()
        transition = nil
        drawGeneration += 1
        finished = false
        failure = nil
        musicID = state.musicID
        effects = state.effects ?? LucaStageEffects()
        sounds = [.stopVoice, .stopEffect(channel: -1, fadeFrames: 0)]
        sounds.append(state.musicID.map { .music(id: $0, fadeFrames: 30) } ?? .stopMusic(fadeFrames: 0))
        if let variable = state.choiceVariable, state.choices != nil {
            wait = .choice(variable: variable)
        } else if state.message != nil {
            wait = .click
        } else {
            wait = .none
        }
        // The line on screen is where the next rewind starts from.
        if message != nil, frame.index > 0, frame.index <= frame.script.instructions.count {
            messageKey = Self.key(frame.script.name, frame.script.instructions[frame.index - 1].position)
            history = [(lineSerial, saveState(withBacklog: false))]
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
