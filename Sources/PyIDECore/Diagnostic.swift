import Foundation

/// A compiler / analyzer diagnostic published by the language server.
public struct Diagnostic: Sendable, Hashable, Identifiable {
    public enum Severity: Int, Sendable {
        case error = 1, warning, information, hint
    }

    public let id: UUID
    public let start: TextPosition
    public let end: TextPosition
    public let severity: Severity
    public let message: String
    public let source: String?
    /// Rule code, e.g. "F401" (ruff) or "reportUndefinedVariable" (pyright).
    public let code: String?
    /// The original LSP object, sent back in `codeAction` requests (ruff keeps its fix there).
    public let raw: JSONValue?

    public init(start: TextPosition, end: TextPosition, severity: Severity, message: String, source: String? = nil,
                code: String? = nil, raw: JSONValue? = nil) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
        self.raw = raw
    }

    /// The message's first line (ruff appends "help: …" after a blank line).
    public var summary: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? message
    }

    /// Parses one LSP `Diagnostic` object.
    public static func parse(_ value: JSONValue) -> Diagnostic? {
        guard let range = value["range"],
              let start = parsePosition(range["start"]),
              let end = parsePosition(range["end"]),
              let message = value["message"]?.stringValue
        else { return nil }
        let severity = Severity(rawValue: value["severity"]?.intValue ?? 1) ?? .error
        let code = value["code"]?.stringValue ?? value["code"]?.intValue.map(String.init)
        return Diagnostic(start: start, end: end, severity: severity, message: message,
                          source: value["source"]?.stringValue, code: code, raw: value)
    }

    /// Parses `textDocument/publishDiagnostics` params.
    public static func parsePublish(_ params: JSONValue) -> (uri: String, diagnostics: [Diagnostic])? {
        guard let uri = params["uri"]?.stringValue else { return nil }
        let diagnostics = (params["diagnostics"]?.arrayValue ?? [])
            .compactMap(parse)
            .sorted { ($0.start.line, $0.start.character) < ($1.start.line, $1.start.character) }
        return (uri, diagnostics)
    }

    private static func parsePosition(_ value: JSONValue?) -> TextPosition? {
        guard let line = value?["line"]?.intValue, let character = value?["character"]?.intValue else { return nil }
        return TextPosition(line: line, character: character)
    }
}
