import Foundation

/// Concatenates a notebook's code cells into one virtual Python document, so a language server
/// sees earlier cells' imports and definitions, and maps cell positions into it.
public struct NotebookSourceMap: Sendable, Equatable {
    /// The virtual document's text.
    public let text: String
    /// Zero-based line where each code cell starts, keyed by cell index.
    public let startLines: [Int: Int]

    /// `cells` is (index, source) for every code cell, in notebook order.
    public init(codeCells: [(index: Int, source: String)]) {
        var text = ""
        var startLines: [Int: Int] = [:]
        var line = 0
        for (index, source) in codeCells {
            startLines[index] = line
            let cleaned = Self.neutralizeMagics(source)
            text += cleaned
            line += cleaned.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            // Separate cells with a blank line; make sure each cell ends its last line first.
            if !cleaned.hasSuffix("\n") {
                text += "\n"
                line += 1
            }
            text += "\n"
            line += 1
        }
        self.text = text
        self.startLines = startLines
    }

    /// The virtual-document position of a UTF-16 offset inside cell `index`.
    public func position(cell index: Int, source: String, offset: Int) -> TextPosition? {
        guard let start = startLines[index] else { return nil }
        let local = LineIndex(source).position(of: offset)
        return TextPosition(line: start + local.line, character: local.character)
    }

    /// IPython magics (`%time`, `!pip install …`) aren't Python; comment them out in place so line
    /// and column positions stay the same.
    static func neutralizeMagics(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let first = trimmed.first, first == "%" || first == "!" else { return String(line) }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return indent + "#" + trimmed.dropFirst()
        }.joined(separator: "\n")
    }
}
