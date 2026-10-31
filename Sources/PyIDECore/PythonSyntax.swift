import Foundation
import SwiftTreeSitter
import TreeSitterPythonGrammar

/// Highlighting from a tree-sitter parse of the whole file: keywords, soft keywords and names
/// are classified by their place in the syntax tree rather than by the text around them.
/// Regions the parser can't make sense of (half-typed code) fall back to the regex lexer.
enum PythonSyntax {
    static let language = Language(tree_sitter_python())

    static func tokenize(_ text: String) -> [PyToken]? {
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil,
              let tree = parser.parse(text), let root = tree.rootNode
        else { return nil }
        var walker = Walker(text: text as NSString)
        walker.visit(root, field: nil, parent: nil)
        var tokens = walker.tokens
        if !walker.fallbackTokens.isEmpty {
            // In regions that didn't parse, the regex lexer's view wins (e.g. an unclosed string
            // the parser recovered from by ending it early).
            let fallback = walker.fallbackTokens
            tokens.removeAll { token in fallback.contains { NSIntersectionRange($0.range, token.range).length > 0 } }
            tokens += fallback
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    private struct Walker {
        let text: NSString
        var tokens: [PyToken] = []
        private(set) var fallbackTokens: [PyToken] = []
        private var regexTokens: [PyToken]?
        private var typeDepth = 0

        init(text: NSString) { self.text = text }

        static let anonymousKeywords: Set<String> = PythonHighlighter.keywords.union(["match", "case", "is not", "not in", "print", "exec", "type"])

        mutating func visit(_ node: Node, field: String?, parent: Node?) {
            guard let type = node.nodeType else { return }
            if !node.isNamed {
                // `type` is only a keyword in `type X = …` statements (as an anonymous token).
                if Self.anonymousKeywords.contains(type), type != "print", type != "exec" {
                    add(node.range, .keyword)
                }
                return
            }
            switch type {
            case "comment":
                add(node.range, .comment)
            case "string":
                visitString(node)
            case "integer", "float":
                add(node.range, .number)
            case "true", "false", "none", "ellipsis" where type != "ellipsis":
                add(node.range, .keyword)
            case "decorator":
                visitDecorator(node)
            case "identifier":
                classifyIdentifier(node, field: field, parent: parent)
            case "keyword_identifier":
                // A soft keyword used as a name (`match = …`): color it like any name.
                classifyIdentifier(node, field: field, parent: parent)
            case "ERROR":
                fallBack(to: node.range)
            default:
                if type == "type" { typeDepth += 1 }
                visitChildren(node)
                if type == "type" { typeDepth -= 1 }
            }
        }

        private mutating func visitChildren(_ node: Node) {
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(child, field: node.fieldNameForChild(at: index), parent: node)
            }
        }

        /// A string literal is one string token, except f-string replacement fields, which are code.
        private mutating func visitString(_ node: Node) {
            var cursor = node.range.location
            for index in 0..<node.childCount {
                guard let child = node.child(at: index), child.nodeType == "interpolation" else { continue }
                add(NSRange(location: cursor, length: child.range.location - cursor), .string)
                cursor = NSMaxRange(child.range)
                for part in 0..<child.childCount {
                    guard let piece = child.child(at: part), piece.isNamed else { continue }
                    if piece.nodeType == "format_specifier" || piece.nodeType == "type_conversion" {
                        add(piece.range, .string)
                    } else {
                        visit(piece, field: child.fieldNameForChild(at: part), parent: child)
                    }
                }
            }
            add(NSRange(location: cursor, length: NSMaxRange(node.range) - cursor), .string)
        }

        /// `@name`, `@a.b` and `@a.b(args)`: the decorator name is highlighted, arguments are code.
        private mutating func visitDecorator(_ node: Node) {
            guard let expression = node.namedChild(at: 0) else {
                add(node.range, .decorator)
                return
            }
            let name = expression.nodeType == "call" ? expression.child(byFieldName: "function") ?? expression : expression
            let start = node.range.location
            add(NSRange(location: start, length: NSMaxRange(name.range) - start), .decorator)
            if expression.nodeType == "call", let arguments = expression.child(byFieldName: "arguments") {
                visit(arguments, field: "arguments", parent: expression)
            }
        }

        private mutating func classifyIdentifier(_ node: Node, field: String?, parent: Node?) {
            let range = node.range
            let name = text.substring(with: range)
            switch (parent?.nodeType, field) {
            case ("function_definition", "name"):
                add(range, .function)
            case ("class_definition", "name"):
                add(range, .type)
            case ("attribute", "attribute"):
                // `x.print` is never the builtin; it's a method when called.
                if let attribute = parent, let call = attribute.parent, call.nodeType == "call",
                   call.child(byFieldName: "function") == attribute {
                    add(range, .function)
                }
            case ("call", "function"):
                add(range, PythonHighlighter.types.contains(name) ? .type
                    : PythonHighlighter.builtins.contains(name) ? .builtin : .function)
            default:
                if typeDepth > 0 || PythonHighlighter.types.contains(name) {
                    add(range, .type)
                } else if PythonHighlighter.builtins.contains(name) {
                    add(range, .builtin)
                }
            }
        }

        /// Uses the regex lexer's tokens inside a region the parser couldn't parse.
        private mutating func fallBack(to range: NSRange) {
            if regexTokens == nil { regexTokens = PythonHighlighter.regexTokenize(text as String) }
            for token in regexTokens! where NSIntersectionRange(token.range, range).length > 0
                && !fallbackTokens.contains(token) {
                fallbackTokens.append(token)
            }
        }

        private mutating func add(_ range: NSRange, _ kind: PyTokenKind) {
            guard range.length > 0 else { return }
            tokens.append(PyToken(range: range, kind: kind))
        }
    }
}
