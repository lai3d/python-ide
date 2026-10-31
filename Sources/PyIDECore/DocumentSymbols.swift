import Foundation

/// A class / function / variable in the current file, for the Outline sidebar.
public struct OutlineSymbol: Sendable, Hashable, Identifiable {
    /// LSP `SymbolKind` values we care about (others map to `.other`).
    public enum Kind: Sendable, Hashable {
        case module, classType, method, property, field, constructor, function, variable, constant, other
    }

    public let id: UUID
    public let name: String
    public let kind: Kind
    public let detail: String?
    /// Where to jump (the name, not the whole body).
    public let position: TextPosition
    /// The full range's line span, to find the symbol containing the caret.
    public let startLine: Int
    public let endLine: Int
    /// nil for leaves, so outline lists show no disclosure triangle.
    public let children: [OutlineSymbol]?

    public init(name: String, kind: Kind, detail: String? = nil, position: TextPosition,
                startLine: Int, endLine: Int, children: [OutlineSymbol]? = nil) {
        self.id = UUID()
        self.name = name
        self.kind = kind
        self.detail = detail
        self.position = position
        self.startLine = startLine
        self.endLine = endLine
        self.children = children
    }

    static func kind(_ raw: Int?) -> Kind {
        switch raw {
        case 2: .module
        case 5: .classType
        case 6: .method
        case 7: .property
        case 8: .field
        case 9: .constructor
        case 12: .function
        case 13: .variable
        case 14: .constant
        default: .other
        }
    }

    /// Parses `DocumentSymbol[]` (hierarchical) or `SymbolInformation[]` (flat, nested by containment).
    public static func parse(_ result: JSONValue) -> [OutlineSymbol] {
        let items = result.arrayValue ?? []
        if items.first?["location"] != nil { return parseFlat(items) }
        return items.compactMap(parseHierarchical).sorted { $0.startLine < $1.startLine }
    }

    private static func parseHierarchical(_ value: JSONValue) -> OutlineSymbol? {
        guard let name = value["name"]?.stringValue,
              let range = value["range"],
              let start = TextPosition(json: range["start"]),
              let end = TextPosition(json: range["end"])
        else { return nil }
        let selection = TextPosition(json: value["selectionRange"]?["start"]) ?? start
        let children = (value["children"]?.arrayValue ?? []).compactMap(parseHierarchical).sorted { $0.startLine < $1.startLine }
        return OutlineSymbol(name: name, kind: kind(value["kind"]?.intValue), detail: value["detail"]?.stringValue,
                             position: selection, startLine: start.line, endLine: end.line,
                             children: children.isEmpty ? nil : children)
    }

    private static func parseFlat(_ items: [JSONValue]) -> [OutlineSymbol] {
        struct Flat { let name: String; let kind: Kind; let start: TextPosition; let end: TextPosition }
        let flat: [Flat] = items.compactMap { item in
            guard let name = item["name"]?.stringValue, let range = item["location"]?["range"],
                  let start = TextPosition(json: range["start"]), let end = TextPosition(json: range["end"]) else { return nil }
            return Flat(name: name, kind: kind(item["kind"]?.intValue), start: start, end: end)
        }.sorted { ($0.start.line, $0.end.line) < ($1.start.line, $1.end.line) }

        func build(_ slice: ArraySlice<Flat>) -> [OutlineSymbol] {
            var result: [OutlineSymbol] = []
            var i = slice.startIndex
            while i < slice.endIndex {
                let parent = slice[i]
                var j = i + 1
                while j < slice.endIndex, slice[j].start.line >= parent.start.line, slice[j].end.line <= parent.end.line { j += 1 }
                let children = build(slice[(i + 1)..<j])
                result.append(OutlineSymbol(name: parent.name, kind: parent.kind, position: parent.start,
                                            startLine: parent.start.line, endLine: parent.end.line,
                                            children: children.isEmpty ? nil : children))
                i = j
            }
            return result
        }
        return build(flat[...])
    }

    /// The innermost symbol whose range contains `line`.
    public static func innermost(containing line: Int, in symbols: [OutlineSymbol]) -> OutlineSymbol? {
        for symbol in symbols where symbol.startLine <= line && line <= symbol.endLine {
            return innermost(containing: line, in: symbol.children ?? []) ?? symbol
        }
        return nil
    }
}
