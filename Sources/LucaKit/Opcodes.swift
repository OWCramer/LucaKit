// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// Opcode names by number for Summer Pockets REFLECTION BLUE (LuckSystem's
/// `data/SummerPocketsRB.txt`, MIT). Each Luca System game numbers its opcodes differently.
public enum LucaOpcodes {
    public static let reflectionBlue: [String] = [
        "EQU", "EQUN", "EQUV", "ADD", "SUB", "MUL", "DIV", "MOD", "AND", "OR", "RANDOM", "VARSTR",
        "VARSTR_ADD", "SET", "FLAGCLR", "GOTO", "ONGOTO", "GOSUB", "IFY", "IFN", "RETURN", "JUMP",
        "FARCALL", "FARRETURN", "JUMPPOINT", "END", "STARTUP_BEGIN", "STARTUP_END", "TASKSCRVAR",
        "VARSTR_SET", "VARSTR_ALLOC", "ARFLAGSET", "COLORBG_SET", "SPLINE_SET", "SHAKELIST_SET",
        "SCISSOR_TRIANGLELIST_SET", "MESSAGE", "MESSAGE_CLEAR", "MESSAGE_WAIT", "MESSAGE_AR_SET",
        "SELECT", "CLOSE_WINDOW", "FADE_WINDOW", "LOG_BEGIN", "LOG_BREAK", "LOG_END", "VOICE",
        "VOICE_STOP", "WAIT_COUNT", "WAIT_TIME", "WAIT_TEXTFEED", "COUNTER_WAIT", "FFSTOP", "INIT",
        "STOP", "IMAGELOAD", "IMAGEUPDATE", "ARC", "MOVE", "MOVE_SKIP", "ROT", "PEND", "FADE", "SCALE",
        "SHAKE", "SHAKELIST", "BASE", "MCMOVE", "MCARC", "MCROT", "MCSHAKE", "MCFADE", "WAIT",
        "WAIT_BSKIP", "DRAW", "WIPE", "FRAMEON", "FRAMEOFF", "FW", "SCISSOR", "DELAY", "RASTER", "TONE",
        "SCALECOSSIN", "BMODE", "SIZE", "SPLINE", "DISP", "MASK", "FACE", "SEPIA", "SEPIA_COLOR",
        "CUSTOMMOVE", "SWAP", "ADDCOLOR", "SUBCOLOR", "SATURATION", "CONTRAST", "PRIORITY", "UVWH",
        "EVSCROLL", "COLORLEVEL", "NEGA", "TONECURVE", "SKIP_SCOPE_BEGIN", "SKIP_SCOPE_END", "QUAKE",
        "BGM", "BGM_WAIT_START", "BGM_WAIT_FADE", "BGM_PUSH", "BGM_POP", "BGM_ASYNC_FADE_STOP", "SE",
        "SE_STOP", "SE_WAIT", "SE_WAIT_COUNT", "SE_WAIT_FADE", "VOLUME", "MOVIE", "SETCGFLAG", "EX",
        "TROPHY", "SETBGMFLAG", "TASK", "PRINTF", "DIALOG", "VIB_PLAY", "VIB_FILE", "VIB_STOP",
        "CHAR_VOLUME", "SCENE_REPLAY_END", "SAVE_THUMBNAIL", "TEXTURE_PREFETCH", "CLOSE_PRELOAD_FILE",
        "CLEAR_UNDO_INFO", "BACKJUMP_LOG_RESTORE_POINT", "MANPU", "SCENARIO", "UNKNOWN",
    ]

    public static func name(_ opcode: UInt8, table: [String] = reflectionBlue) -> String {
        Int(opcode) < table.count ? table[Int(opcode)] : "OP_\(opcode)"
    }
}

/// An instruction with its parameters read, for the opcodes whose layout is known.
public enum LucaOp: Sendable {
    /// `IFY`/`IFN`: jump to `target` when the expression is true (IFY) / false (IFN).
    case branch(ifTrue: Bool, expression: String, target: Int)
    case goto(target: Int)
    case gosub(value: UInt16, target: Int)
    /// Another script, at a byte offset (0: its start).
    case jump(script: String, target: Int?)
    case farcall(value: UInt16, script: String, target: Int)
    case message(voice: UInt16, japanese: String, english: String, chinese: String, extra: [UInt16])
    case select(values: [UInt16], japanese: String, english: String, chinese: String, extra: [UInt16])
    case varstrSet(file: String, variable: UInt16, japanese: String, english: String, chinese: String)
    case logBegin(value: UInt16, flag: UInt8, japanese: String, english: String, chinese: String)
    case dialog(values: [UInt16], japanese: String)
    case movie(file: String, extra: [UInt16])
    /// `EQU` and friends: a variable and an expression or value.
    case expression(op: String, variable: UInt16, text: String?, values: [UInt16])
    case raw(name: String, values: [UInt16], tail: UInt8?)

    public static func decode(_ instruction: LucaScript.Instruction, table: [String] = LucaOpcodes.reflectionBlue) -> LucaOp {
        let name = LucaOpcodes.name(instruction.opcode, table: table)
        var r = ParamReader(instruction.params)
        switch name {
        case "IFY", "IFN":
            let expr = r.lstrUTF8()
            return .branch(ifTrue: name == "IFY", expression: expr, target: Int(r.u32()))
        case "GOTO":
            return .goto(target: Int(r.u32()))
        case "GOSUB":
            let v = r.u16()
            return .gosub(value: v, target: Int(r.u32()))
        case "JUMP":
            let file = r.lstrUTF8()
            return .jump(script: file, target: r.canRead ? Int(r.u32()) : nil)
        case "FARCALL":
            let v = r.u16()
            let file = r.lstrUTF8()
            return .farcall(value: v, script: file, target: Int(r.u32()))
        case "MESSAGE":
            let voice = r.u16()
            let jp = r.lstrUTF16()
            var en = "", cn = ""
            if !jp.isEmpty {
                en = r.lstrUTF8()
                cn = r.lstrUTF16()
            }
            return .message(voice: voice, japanese: jp, english: en, chinese: cn, extra: r.rest16())
        case "SELECT":
            let values = [r.u16(), r.u16(), r.u16(), r.u16()]
            let jp = r.lstrUTF16()
            var en = "", cn = ""
            if !jp.isEmpty {
                en = r.lstrUTF16()
                cn = r.lstrUTF16()
            }
            return .select(values: values, japanese: jp, english: en, chinese: cn, extra: r.rest16())
        case "VARSTR_SET":
            let file = r.lstrUTF8()
            let variable = r.u16()
            var jp = "", en = "", cn = ""
            if r.remaining > 6 {
                jp = r.lstrUTF16(); en = r.lstrUTF16(); cn = r.lstrUTF16()
            }
            return .varstrSet(file: file, variable: variable, japanese: jp, english: en, chinese: cn)
        case "LOG_BEGIN":
            let v = r.u16()
            let flag = r.u8()
            let jp = r.lstrUTF16()
            let en = r.lstrUTF16()
            let cn = r.remaining > 1 ? r.lstrUTF16() : ""
            return .logBegin(value: v, flag: flag, japanese: jp, english: en, chinese: cn)
        case "DIALOG":
            let values = [r.u16(), r.u16()]
            return .dialog(values: values, japanese: r.lstrUTF16())
        case "MOVIE":
            let file = r.lstrUTF8()
            return .movie(file: file, extra: r.rest16())
        default:
            let tail: UInt8? = instruction.params.count % 2 == 1 ? instruction.params.last : nil
            return .raw(name: name, values: r.rest16(), tail: tail)
        }
    }
}
