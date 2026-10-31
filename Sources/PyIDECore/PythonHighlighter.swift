import Foundation

public enum PyTokenKind: Sendable, Hashable {
    case keyword, type, builtin, function, decorator, string, comment, number
}

public struct PyToken: Sendable, Hashable {
    public let range: NSRange
    public let kind: PyTokenKind

    public init(range: NSRange, kind: PyTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A fast, regex-based Python lexer for syntax highlighting.
/// (A tree-sitter grammar can replace this later for incremental parsing.)
public enum PythonHighlighter {
    public static let keywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ]

    /// Soft keywords: only keywords when they start a block statement (`match x:` / `case 1:`).
    public static let softKeywords: Set<String> = ["match", "case"]

    public static let types: Set<String> = [
        "bool", "bytearray", "bytes", "complex", "dict", "float", "frozenset", "int", "list", "memoryview",
        "object", "range", "set", "slice", "str", "tuple", "type",
        "BaseException", "Exception", "ArithmeticError", "AssertionError", "AttributeError", "EOFError",
        "ImportError", "IndexError", "KeyError", "KeyboardInterrupt", "LookupError", "ModuleNotFoundError",
        "NameError", "NotImplementedError", "OSError", "FileNotFoundError", "RuntimeError", "StopIteration",
        "SyntaxError", "SystemExit", "TypeError", "ValueError", "ZeroDivisionError",
    ]

    public static let builtins: Set<String> = [
        "abs", "aiter", "all", "anext", "any", "ascii", "bin", "breakpoint", "callable", "chr", "classmethod",
        "compile", "delattr", "dir", "divmod", "enumerate", "eval", "exec", "filter", "format", "getattr",
        "globals", "hasattr", "hash", "help", "hex", "id", "input", "isinstance", "issubclass", "iter", "len",
        "locals", "map", "max", "min", "next", "oct", "open", "ord", "pow", "print", "property", "repr",
        "reversed", "round", "setattr", "sorted", "staticmethod", "sum", "super", "vars", "zip", "__import__",
        "self", "cls", "NotImplemented", "Ellipsis", "__name__", "__file__",
    ]

    private static let stringPrefix = #"(?:[rRbBuUfFtT]{1,2})?"#

    // Alternation order matters: comments and strings win over anything inside them.
    private static let regex = try! NSRegularExpression(pattern: [
        #"(#[^\n]*)"#,                                                                    // 1: comment
        "(\(stringPrefix)(?:\"\"\"[\\s\\S]*?(?:\"\"\"|$(?![\\s\\S]))|'''[\\s\\S]*?(?:'''|$(?![\\s\\S]))"
            + #"|"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?))"#,                             // 2: string
        #"(?:(?<=\n)|^)[ \t]*(@[\p{L}_][\p{L}\p{Nd}_.]*)"#,                              // 3: decorator
        #"((?<![\p{L}\p{Nd}_])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:\d[\d_]*\.?[\d_]*|\.\d[\d_]*)(?:[eE][+-]?\d+)?[jJ]?))"#, // 4: number
        #"([\p{L}_][\p{L}\p{Nd}_]*)"#,                                                   // 5: identifier
    ].joined(separator: "|"))

    public static func tokenize(_ text: String) -> [PyToken] {
        let ns = text as NSString
        var tokens: [PyToken] = []
        var previousWord: String?
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 1), kind: .comment))
            } else if match.range(at: 2).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 2), kind: .string))
                previousWord = nil
            } else if match.range(at: 3).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 3), kind: .decorator))
                previousWord = nil
            } else if match.range(at: 4).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 4), kind: .number))
                previousWord = nil
            } else {
                let range = match.range(at: 5)
                let word = ns.substring(with: range)
                defer { previousWord = word }
                if previousWord == "def" {
                    tokens.append(PyToken(range: range, kind: .function))
                } else if previousWord == "class" {
                    tokens.append(PyToken(range: range, kind: .type))
                } else if isPrecededByDot(ns, at: range.location) {
                    // Attribute access: `x.print` is never the builtin.
                    if isFollowedByParen(ns, at: NSMaxRange(range)) {
                        tokens.append(PyToken(range: range, kind: .function))
                    }
                } else if keywords.contains(word) {
                    tokens.append(PyToken(range: range, kind: .keyword))
                } else if softKeywords.contains(word), isSoftKeywordStatement(ns, wordRange: range) {
                    tokens.append(PyToken(range: range, kind: .keyword))
                } else if types.contains(word) {
                    tokens.append(PyToken(range: range, kind: .type))
                } else if builtins.contains(word) {
                    tokens.append(PyToken(range: range, kind: .builtin))
                } else if isFollowedByParen(ns, at: NSMaxRange(range)) {
                    tokens.append(PyToken(range: range, kind: .function))
                }
            }
        }
        return tokens
    }

    private static func isFollowedByParen(_ ns: NSString, at index: Int) -> Bool {
        var i = index
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x28 { return true }             // (
            if c != 0x20 && c != 0x09 { return false } // space / tab
            i += 1
        }
        return false
    }

    private static func isPrecededByDot(_ ns: NSString, at index: Int) -> Bool {
        var i = index - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x2E { return true }             // .
            if c != 0x20 && c != 0x09 { return false }
            i -= 1
        }
        return false
    }

    /// `match`/`case` count as keywords when they begin a line that ends with `:`.
    private static func isSoftKeywordStatement(_ ns: NSString, wordRange: NSRange) -> Bool {
        let line = ns.lineRange(for: wordRange)
        let before = ns.substring(with: NSRange(location: line.location, length: wordRange.location - line.location))
        guard before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }
        let rest = ns.substring(with: NSRange(location: NSMaxRange(wordRange),
                                              length: NSMaxRange(line) - NSMaxRange(wordRange)))
        guard let next = rest.first, next == " " || next == "\t" else { return false }
        let code = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return code.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":")
    }
}

/// Python-aware indentation rules for the editor (4-space indents).
public enum PythonIndent {
    public static let unit = "    "

    /// Indentation for the line after `line` (the text before the caret on the current line).
    public static func indentAfter(line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let code = stripComment(line).trimmingCharacters(in: .whitespaces)
        if code.hasSuffix(":") || code.hasSuffix("(") || code.hasSuffix("[") || code.hasSuffix("{") {
            return indent + unit
        }
        let firstWord = code.prefix { $0.isLetter || $0 == "_" }
        if ["return", "pass", "break", "continue", "raise"].contains(firstWord) {
            return String(indent.dropLast(min(unit.count, indent.count)))
        }
        return indent
    }

    /// Number of spaces to delete when backspacing at `column` in an all-space indent.
    public static func dedentWidth(column: Int) -> Int {
        guard column > 0 else { return 0 }
        let remainder = column % unit.count
        return remainder == 0 ? unit.count : remainder
    }

    /// Removes a trailing `# comment` that isn't inside a string literal.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (i, ch) in zip(line.indices, line) {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return String(line[..<i])
            }
        }
        return line
    }
}
