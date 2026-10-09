import Foundation

/// Luca System condition and assignment expressions: `(#12008==0)`,
/// `((#24006>=6)&&#3!=1)`, `(#14003&4)`, `@get_flag(3)`.
///
/// `#N` is integer variable N; `@name` or `@name(args)` calls a game function (the minigame
/// helpers), answered by `functions`. Operators, loosest first: `||`, `&&`, `|`, `^`, `&`,
/// `== !=`, `< <= > >=`, `<< >>`, `+ -`, `* / %`, unary `! - ~`.
public struct LucaExpression {
    public typealias Variables = (Int) -> Int
    public typealias Functions = (String, [Int]) -> Int

    private let chars: [Character]
    private var i = 0
    private let variable: Variables
    private let function: Functions

    public static func evaluate(_ text: String, variables: @escaping Variables, functions: @escaping Functions = { _, _ in 0 }) -> Int {
        var parser = LucaExpression(chars: Array(text), variable: variables, function: functions)
        return parser.orExpr()
    }

    private init(chars: [Character], variable: @escaping Variables, function: @escaping Functions) {
        self.chars = chars
        self.variable = variable
        self.function = function
    }

    private mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }

    private mutating func eat(_ s: String) -> Bool {
        skip()
        let token = Array(s)
        guard i + token.count <= chars.count, Array(chars[i..<(i + token.count)]) == token else { return false }
        // Don't take "&" from "&&", "|" from "||", "<" from "<<"/"<=", and so on.
        if token.count == 1, i + 1 < chars.count {
            let next = chars[i + 1]
            switch token[0] {
            case "&": if next == "&" { return false }
            case "|": if next == "|" { return false }
            case "<", ">": if next == "=" || next == token[0] { return false }
            case "=": if next == "=" { return false }
            case "!": if next == "=" { return false }
            default: break
            }
        }
        i += token.count
        return true
    }

    private mutating func orExpr() -> Int {
        var v = andExpr()
        while eat("||") { let r = andExpr(); v = (v != 0 || r != 0) ? 1 : 0 }
        return v
    }

    private mutating func andExpr() -> Int {
        var v = bitOr()
        while eat("&&") { let r = bitOr(); v = (v != 0 && r != 0) ? 1 : 0 }
        return v
    }

    private mutating func bitOr() -> Int {
        var v = bitXor()
        while eat("|") { v |= bitXor() }
        return v
    }

    private mutating func bitXor() -> Int {
        var v = bitAnd()
        while eat("^") { v ^= bitAnd() }
        return v
    }

    private mutating func bitAnd() -> Int {
        var v = equality()
        while eat("&") { v &= equality() }
        return v
    }

    private mutating func equality() -> Int {
        var v = relational()
        while true {
            if eat("==") { v = v == relational() ? 1 : 0 }
            else if eat("!=") { v = v != relational() ? 1 : 0 }
            else { return v }
        }
    }

    private mutating func relational() -> Int {
        var v = shift()
        while true {
            if eat("<=") { v = v <= shift() ? 1 : 0 }
            else if eat(">=") { v = v >= shift() ? 1 : 0 }
            else if eat("<") { v = v < shift() ? 1 : 0 }
            else if eat(">") { v = v > shift() ? 1 : 0 }
            else { return v }
        }
    }

    private mutating func shift() -> Int {
        var v = additive()
        while true {
            if eat("<<") { v <<= additive() & 63 }
            else if eat(">>") { v >>= additive() & 63 }
            else { return v }
        }
    }

    private mutating func additive() -> Int {
        var v = multiplicative()
        while true {
            if eat("+") { v &+= multiplicative() }
            else if eat("-") { v &-= multiplicative() }
            else { return v }
        }
    }

    private mutating func multiplicative() -> Int {
        var v = unary()
        while true {
            if eat("*") { v &*= unary() }
            else if eat("/") { let r = unary(); v = r == 0 ? 0 : v / r }
            else if eat("%") { let r = unary(); v = r == 0 ? 0 : v % r }
            else { return v }
        }
    }

    private mutating func unary() -> Int {
        if eat("!") { return unary() == 0 ? 1 : 0 }
        if eat("-") { return -unary() }
        if eat("~") { return ~unary() }
        return primary()
    }

    private mutating func primary() -> Int {
        skip()
        guard i < chars.count else { return 0 }
        if eat("(") {
            let v = orExpr()
            _ = eat(")")
            return v
        }
        if chars[i] == "#" {
            i += 1
            return variable(number())
        }
        if chars[i] == "@" {
            i += 1
            var name = ""
            while i < chars.count, !"()=!<>&|+-*/%^, ".contains(chars[i]) {
                name.append(chars[i]); i += 1
            }
            var args: [Int] = []
            if eat("(") {
                if !eat(")") {
                    repeat { args.append(orExpr()) } while eat(",")
                    _ = eat(")")
                }
            }
            return function(name, args)
        }
        if chars[i].isNumber { return number() }
        i += 1 // unknown character: skip it rather than loop
        return 0
    }

    private mutating func number() -> Int {
        var v = 0
        while i < chars.count, let d = chars[i].wholeNumberValue, chars[i].isASCII {
            v = v * 10 + d
            i += 1
        }
        return v
    }
}
