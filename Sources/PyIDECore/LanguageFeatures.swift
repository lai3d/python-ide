import Foundation

// MARK: - Positions

public extension TextPosition {
    /// Parses an LSP `Position` object.
    init?(json: JSONValue?) {
        guard let line = json?["line"]?.intValue, let character = json?["character"]?.intValue else { return nil }
        self.init(line: line, character: character)
    }

    var json: JSONValue { ["line": .int(line), "character": .int(character)] }
}

/// An LSP `TextEdit` (or the `replace` half of an `InsertReplaceEdit`).
public struct TextEdit: Sendable, Hashable {
    public let start: TextPosition
    public let end: TextPosition
    public let newText: String

    public init(start: TextPosition, end: TextPosition, newText: String) {
        self.start = start
        self.end = end
        self.newText = newText
    }

    public static func parse(_ value: JSONValue) -> TextEdit? {
        guard let newText = value["newText"]?.stringValue,
              let range = value["range"] ?? value["replace"] ?? value["insert"],
              let start = TextPosition(json: range["start"]),
              let end = TextPosition(json: range["end"])
        else { return nil }
        return TextEdit(start: start, end: end, newText: newText)
    }
}

// MARK: - Completion

public struct CompletionItem: Sendable, Hashable, Identifiable {
    /// LSP `CompletionItemKind`.
    public enum Kind: Int, Sendable {
        case text = 1, method, function, constructor, field, variable, classType, interface, module,
             property, unit, value, enumType, keyword, snippet, color, file, reference, folder,
             enumMember, constant, structType, event, operatorKind, typeParameter
    }

    public let id: UUID
    public let label: String
    public let kind: Kind
    public let detail: String?
    public let documentation: String?
    /// Text that replaces the identifier prefix before the caret.
    public let insertText: String
    public let filterText: String
    public let sortText: String
    /// Edits elsewhere in the file, e.g. an automatically added import.
    public let additionalEdits: [TextEdit]

    public init(label: String, kind: Kind = .text, detail: String? = nil, documentation: String? = nil,
                insertText: String? = nil, filterText: String? = nil, sortText: String? = nil,
                additionalEdits: [TextEdit] = []) {
        self.id = UUID()
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText ?? label
        self.filterText = filterText ?? label
        self.sortText = sortText ?? label
        self.additionalEdits = additionalEdits
    }

    public static func parse(_ value: JSONValue) -> CompletionItem? {
        guard let label = value["label"]?.stringValue else { return nil }
        var insert = value["textEdit"].flatMap(TextEdit.parse)?.newText ?? value["insertText"]?.stringValue ?? label
        if value["insertTextFormat"]?.intValue == 2 { insert = stripSnippet(insert) }
        let documentation = value["documentation"]?.stringValue ?? value["documentation"]?["value"]?.stringValue
        return CompletionItem(
            label: label,
            kind: Kind(rawValue: value["kind"]?.intValue ?? 1) ?? .text,
            detail: value["detail"]?.stringValue,
            documentation: documentation,
            insertText: insert,
            filterText: value["filterText"]?.stringValue,
            sortText: value["sortText"]?.stringValue,
            additionalEdits: value["additionalTextEdits"]?.arrayValue?.compactMap(TextEdit.parse) ?? [])
    }

    /// Parses a completion result (`CompletionItem[]` or `CompletionList`), ordered by `sortText`.
    public static func parseList(_ result: JSONValue) -> [CompletionItem] {
        let raw = result.arrayValue ?? result["items"]?.arrayValue ?? []
        return raw.compactMap(parse)
            .enumerated()
            .sorted { ($0.element.sortText, $0.offset) < ($1.element.sortText, $1.offset) }
            .map(\.element)
    }

    /// Turns `Foo(${1:x}, $2)$0` into `Foo(x, )`. We don't advertise snippet support,
    /// but stay safe if a server sends snippets anyway.
    public static func stripSnippet(_ snippet: String) -> String {
        var s = snippet.replacingOccurrences(of: #"\$\{\d+:([^}]*)\}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\$\{\d+\}|\$\d+"#, with: "", options: .regularExpression)
        return s
    }
}

/// Case-insensitive subsequence matching used to filter completions as you type.
public enum FuzzyMatch {
    public static func matches(_ pattern: String, _ candidate: String) -> Bool {
        guard let first = pattern.first else { return true }
        guard let candidateFirst = candidate.first,
              first.lowercased() == candidateFirst.lowercased() else { return false }
        var remaining = candidate.lowercased()[...]
        for ch in pattern.lowercased() {
            guard let i = remaining.firstIndex(of: ch) else { return false }
            remaining = remaining[remaining.index(after: i)...]
        }
        return true
    }
}

// MARK: - Hover

public enum HoverContent {
    /// Extracts markdown from a hover result (`MarkupContent`, `MarkedString` or `MarkedString[]`).
    public static func parse(_ result: JSONValue) -> String? {
        guard let contents = result["contents"] else { return nil }
        func text(_ v: JSONValue) -> String? {
            if let s = v.stringValue { return s }
            guard let value = v["value"]?.stringValue else { return nil }
            if let language = v["language"]?.stringValue { return "```\(language)\n\(value)\n```" }
            return value
        }
        let markdown = contents.arrayValue.map { $0.compactMap(text).joined(separator: "\n\n") } ?? text(contents)
        guard let markdown = markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !markdown.isEmpty else { return nil }
        return markdown
    }
}

/// Splits markdown into fenced code blocks and prose, which is all hover rendering needs.
public struct MarkdownBlock: Sendable, Hashable {
    public enum Kind: Sendable { case code, text }
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var current: [Substring] = []
        var inCode = false
        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(MarkdownBlock(kind: inCode ? .code : .text, text: text)) }
            current = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                inCode.toggle()
            } else if !inCode, trimmed.count >= 3, Set(trimmed).count == 1, "-*_".contains(trimmed.first!) {
                flush()  // horizontal rule: just a block separator
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }
}

// MARK: - Definition

public struct Location: Sendable, Hashable {
    public let uri: String
    public let start: TextPosition
    public let end: TextPosition

    public init(uri: String, start: TextPosition, end: TextPosition) {
        self.uri = uri
        self.start = start
        self.end = end
    }

    /// Parses `Location`, `Location[]` or `LocationLink[]`.
    public static func parseAll(_ result: JSONValue) -> [Location] {
        if let array = result.arrayValue { return array.compactMap(parse) }
        return parse(result).map { [$0] } ?? []
    }

    private static func parse(_ value: JSONValue) -> Location? {
        guard let uri = value["uri"]?.stringValue ?? value["targetUri"]?.stringValue,
              let range = value["targetSelectionRange"] ?? value["range"],
              let start = TextPosition(json: range["start"]),
              let end = TextPosition(json: range["end"])
        else { return nil }
        return Location(uri: uri, start: start, end: end)
    }
}

// MARK: - Identifiers

public enum Identifier {
    /// UTF-16 unit that can be part of a Python identifier (non-ASCII treated as letters).
    public static func isIdentifier(_ unit: unichar) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            || unit == 0x5F || unit >= 0x80
    }

    public static func isIdentifierStart(_ unit: unichar) -> Bool {
        isIdentifier(unit) && !(unit >= 0x30 && unit <= 0x39)
    }

    /// Start offset of the identifier that ends at `offset` (== `offset` if none).
    public static func prefixStart(in text: NSString, before offset: Int) -> Int {
        var i = min(max(offset, 0), text.length)
        while i > 0, isIdentifier(text.character(at: i - 1)) { i -= 1 }
        return i
    }

    /// Range of the identifier containing the character at `index`, if any.
    public static func wordRange(in text: NSString, at index: Int) -> NSRange? {
        guard index >= 0, index < text.length, isIdentifier(text.character(at: index)) else { return nil }
        var start = index, end = index + 1
        while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isIdentifier(text.character(at: end)) { end += 1 }
        guard isIdentifierStart(text.character(at: start)) else { return nil }  // a number literal
        return NSRange(location: start, length: end - start)
    }
}
