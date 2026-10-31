import Foundation

// MARK: - Applying edits

public extension TextEdit {
    /// Applies LSP edits (all ranges relative to the original `text`) and returns the new text.
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let index = LineIndex(text)
        let result = NSMutableString(string: text)
        let ranges = edits
            .map { (range: index.range(from: $0.start, to: $0.end), text: $0.newText) }
            .sorted { $0.range.location != $1.range.location ? $0.range.location > $1.range.location
                                                              : $0.range.length > $1.range.length }
        for edit in ranges {
            result.replaceCharacters(in: edit.range, with: edit.text)
        }
        return result as String
    }
}

/// The text edits of an LSP `WorkspaceEdit`, grouped by document URI.
public enum WorkspaceEdit {
    /// Reads both the `changes` map and `documentChanges` (TextDocumentEdit entries; file
    /// create/rename/delete operations are ignored).
    public static func parse(_ value: JSONValue) -> [String: [TextEdit]] {
        var result: [String: [TextEdit]] = [:]
        if let changes = value["changes"]?.objectValue {
            for (uri, edits) in changes {
                result[uri, default: []] += edits.arrayValue?.compactMap(TextEdit.parse) ?? []
            }
        }
        for change in value["documentChanges"]?.arrayValue ?? [] {
            guard let uri = change["textDocument"]?["uri"]?.stringValue else { continue }
            result[uri, default: []] += change["edits"]?.arrayValue?.compactMap(TextEdit.parse) ?? []
        }
        return result.filter { !$0.value.isEmpty }
    }
}

// MARK: - Signature help

public struct SignatureInfo: Sendable, Hashable {
    public let label: String
    /// UTF-16 ranges of each parameter inside `label`.
    public let parameters: [NSRange]
    public let activeParameter: Int?
    public let documentation: String?
    /// e.g. "1/3" when there are overloads.
    public let overloadPosition: String?

    public init(label: String, parameters: [NSRange], activeParameter: Int?, documentation: String?,
                overloadPosition: String? = nil) {
        self.label = label
        self.parameters = parameters
        self.activeParameter = activeParameter
        self.documentation = documentation
        self.overloadPosition = overloadPosition
    }

    public var activeParameterRange: NSRange? {
        guard let activeParameter, parameters.indices.contains(activeParameter) else { return nil }
        return parameters[activeParameter]
    }

    /// Parses a `SignatureHelp` result, picking the active signature.
    public static func parse(_ result: JSONValue) -> SignatureInfo? {
        guard let signatures = result["signatures"]?.arrayValue, !signatures.isEmpty else { return nil }
        let active = min(max(result["activeSignature"]?.intValue ?? 0, 0), signatures.count - 1)
        let signature = signatures[active]
        guard let label = signature["label"]?.stringValue else { return nil }
        let ns = label as NSString
        var searchFrom = 0
        let parameters: [NSRange] = (signature["parameters"]?.arrayValue ?? []).compactMap { parameter in
            if let offsets = parameter["label"]?.arrayValue, offsets.count == 2,
               let start = offsets[0].intValue, let end = offsets[1].intValue, start <= end, end <= ns.length {
                return NSRange(location: start, length: end - start)
            }
            if let text = parameter["label"]?.stringValue {
                let found = ns.range(of: text, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                guard found.location != NSNotFound else { return nil }
                searchFrom = NSMaxRange(found)
                return found
            }
            return nil
        }
        let documentation = signature["documentation"]?.stringValue ?? signature["documentation"]?["value"]?.stringValue
        return SignatureInfo(
            label: label,
            parameters: parameters,
            activeParameter: signature["activeParameter"]?.intValue ?? result["activeParameter"]?.intValue,
            documentation: documentation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            overloadPosition: signatures.count > 1 ? "\(active + 1)/\(signatures.count)" : nil)
    }
}

// MARK: - Rename

public enum PrepareRename {
    /// Parses a `prepareRename` result into the range to rename and a placeholder, if renaming is allowed.
    /// (`Range`, `{range, placeholder}`, or `{defaultBehavior}`; null means "can't rename here".)
    public static func parse(_ result: JSONValue) -> (start: TextPosition, end: TextPosition, placeholder: String?)? {
        let range = result["range"] ?? result
        guard let start = TextPosition(json: range["start"]), let end = TextPosition(json: range["end"]) else { return nil }
        return (start, end, result["placeholder"]?.stringValue)
    }
}

public extension Identifier {
    /// Whether `name` is a valid Python identifier (and not a keyword).
    static func isValidPythonName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else { return false }
        let ok = name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
        return ok && !PythonHighlighter.keywords.contains(name)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
