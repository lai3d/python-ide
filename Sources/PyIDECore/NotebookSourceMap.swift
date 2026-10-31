import Foundation

/// Concatenates a notebook's code cells into one virtual Python document, so a language server
/// sees earlier cells' imports and definitions, and maps cell positions into it.
public struct NotebookSourceMap: Sendable, Equatable {
    /// The virtual document's text.
    public let text: String
    /// Zero-based line where each code cell starts, keyed by cell index.
    public let startLines: [Int: Int]
    /// Number of lines each code cell occupies (excluding the blank separator), keyed by cell index.
    public let lineCounts: [Int: Int]

    /// `cells` is (index, source) for every code cell, in notebook order.
    public init(codeCells: [(index: Int, source: String)]) {
        var text = ""
        var startLines: [Int: Int] = [:]
        var lineCounts: [Int: Int] = [:]
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
            lineCounts[index] = line - startLines[index]!
            text += "\n"
            line += 1
        }
        self.text = text
        self.startLines = startLines
        self.lineCounts = lineCounts
    }

    /// The cell (index) containing a virtual-document line, and the line within that cell.
    public func locate(line: Int) -> (cell: Int, line: Int)? {
        for (cell, start) in startLines where line >= start && line < start + (lineCounts[cell] ?? 0) {
            return (cell, line - start)
        }
        return nil
    }

    /// Splits diagnostics for the virtual document into per-cell diagnostics in cell coordinates.
    /// Drops what doesn't apply to notebooks: a bare expression ending a cell is its output, and
    /// redefining a name in a later cell or awaiting at top level is normal there.
    public func cellDiagnostics(_ diagnostics: [Diagnostic]) -> [Int: [Diagnostic]] {
        var result: [Int: [Diagnostic]] = [:]
        for diagnostic in diagnostics where Self.appliesToNotebooks(diagnostic) {
            guard let (cell, line) = locate(line: diagnostic.start.line) else { continue }
            let count = lineCounts[cell] ?? 1
            let endLine = diagnostic.end.line - startLines[cell]!
            let end = endLine < count
                ? TextPosition(line: endLine, character: diagnostic.end.character)
                : TextPosition(line: count - 1, character: Int.max / 2)
            result[cell, default: []].append(Diagnostic(
                start: TextPosition(line: line, character: diagnostic.start.character), end: end,
                severity: diagnostic.severity, message: diagnostic.message, source: diagnostic.source,
                code: diagnostic.code, raw: diagnostic.raw))
        }
        return result
    }

    static let rulesIgnoredInNotebooks: Set<String> = ["reportUnusedExpression", "reportRedeclaration"]

    static func appliesToNotebooks(_ diagnostic: Diagnostic) -> Bool {
        if diagnostic.severity == .hint { return false }
        if let code = diagnostic.code, rulesIgnoredInNotebooks.contains(code) { return false }
        // IPython runs top-level `await`; pyright's message: "await" allowed only within async function.
        if diagnostic.message.contains("allowed only within async") { return false }
        return true
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
