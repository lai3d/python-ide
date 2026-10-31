import Foundation

/// A parsed Jupyter notebook (nbformat 4), for read-only display.
public struct Notebook: Sendable, Hashable {
    public struct Cell: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case code, markdown, raw }
        public let id: Int
        public let kind: Kind
        public let source: String
        public let executionCount: Int?
        public let outputs: [Output]
    }

    public enum Output: Sendable, Hashable {
        case text(String, isError: Bool)
        case image(Data)
        /// HTML, LaTeX or SVG, rendered in a web view; `kind` is the MIME type.
        case web(String, kind: String)
        case markdown(String)
        case error(name: String, value: String, traceback: String)
    }

    public let cells: [Cell]
    public let language: String

    public enum ParseError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let reason): "Not a valid notebook: \(reason)" }
        }
    }

    public static func parse(_ text: String) throws -> Notebook {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            throw ParseError.invalid("invalid JSON")
        }
        guard let rawCells = root["cells"]?.arrayValue else { throw ParseError.invalid("no cells") }
        let language = root["metadata"]?["kernelspec"]?["language"]?.stringValue
            ?? root["metadata"]?["language_info"]?["name"]?.stringValue ?? "python"
        let cells = rawCells.enumerated().map { index, cell -> Cell in
            let kind: Cell.Kind = switch cell["cell_type"]?.stringValue {
            case "markdown": .markdown
            case "raw": .raw
            default: .code
            }
            return Cell(id: index, kind: kind, source: joined(cell["source"]),
                        executionCount: cell["execution_count"]?.intValue,
                        outputs: (cell["outputs"]?.arrayValue ?? []).compactMap(parseOutput))
        }
        return Notebook(cells: cells, language: language)
    }

    /// nbformat stores multiline strings either as one string or as a list of lines.
    public static func joined(_ value: JSONValue?) -> String {
        if let s = value?.stringValue { return s }
        return (value?.arrayValue ?? []).compactMap(\.stringValue).joined()
    }

    public static func parseOutput(_ output: JSONValue) -> Output? {
        switch output["output_type"]?.stringValue {
        case "stream":
            return .text(joined(output["text"]), isError: output["name"]?.stringValue == "stderr")
        case "execute_result", "display_data":
            let data = output["data"]
            // Richest representation first, like Jupyter.
            if let html = data?["text/html"] { return .web(joined(html), kind: "text/html") }
            if let markdown = data?["text/markdown"] { return .markdown(joined(markdown)) }
            for mime in ["text/latex", "image/svg+xml"] {
                if let value = data?[mime] { return .web(joined(value), kind: mime) }
            }
            for mime in ["image/png", "image/jpeg"] {
                if let base64 = data?[mime].map({ joined($0) }),
                   let bytes = Data(base64Encoded: base64.filter { !$0.isWhitespace }) {
                    return .image(bytes)
                }
            }
            if let plain = data?["text/plain"] { return .text(joined(plain), isError: false) }
            return nil
        case "error":
            let traceback = (output["traceback"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
            return .error(name: output["ename"]?.stringValue ?? "Error",
                          value: output["evalue"]?.stringValue ?? "",
                          traceback: stripANSI(traceback))
        default:
            return nil
        }
    }

    /// Removes terminal color codes (IPython tracebacks are colorized).
    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}
