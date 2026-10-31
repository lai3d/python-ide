import Foundation
import Testing
@testable import PyIDECore

@Suite struct PythonHighlighterTests {
    private func kinds(_ source: String) -> [(String, PyTokenKind)] {
        let ns = source as NSString
        return PythonHighlighter.tokenize(source).map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func classifiesTokens() {
        let tokens = kinds(#"def main(): x = len("hi # no") + 42  # done"#)
        #expect(tokens.map(\.0) == ["def", "main", "len", #""hi # no""#, "42", "# done"])
        #expect(tokens.map(\.1) == [.keyword, .function, .builtin, .string, .number, .comment])
    }

    @Test func handlesTripleQuotedAndPrefixedStrings() {
        let tokens = kinds(#"s: str = f'''a"# + "\n" + #""b" # x'''"# + "\n" + #"b = rb"\d""#)
        #expect(tokens.map(\.1) == [.type, .string, .string])
        #expect(kinds(#"x = """open"#).last?.1 == .string)
    }

    @Test func classesDecoratorsAndAttributes() {
        let tokens = kinds("@dataclass\nclass Point(Base):\n    def __init__(self): self.print(None)")
        #expect(tokens.map(\.0) == ["@dataclass", "class", "Point", "def", "__init__", "self", "self", "print", "None"])
        #expect(tokens.map(\.1) == [.decorator, .keyword, .type, .keyword, .function,
                                    .builtin, .builtin, .function, .keyword])
    }

    @Test func softKeywords() {
        #expect(kinds("match cmd:\n    case [x]:\n        pass").map(\.1) == [.keyword, .keyword, .keyword])
        #expect(kinds("match = re.match(p, s)").map(\.0) == ["match"])  // only the method call
    }

    @Test func numbers() {
        #expect(kinds("a = 0x1F + 1_000 + 3.14e-2 + 2j + .5").filter { $0.1 == .number }.map(\.0)
                == ["0x1F", "1_000", "3.14e-2", "2j", ".5"])
        #expect(kinds("x1 = 2").filter { $0.1 == .number }.map(\.0) == ["2"])
    }
}

@Suite struct PythonIndentTests {
    @Test func indentsAfterBlockOpeners() {
        #expect(PythonIndent.indentAfter(line: "def f(x):") == "    ")
        #expect(PythonIndent.indentAfter(line: "    if x:  # note") == "        ")
        #expect(PythonIndent.indentAfter(line: "    items = [") == "        ")
        #expect(PythonIndent.indentAfter(line: "    x = 1") == "    ")
        #expect(PythonIndent.indentAfter(line: "    s = 'a:'") == "    ")
        #expect(PythonIndent.indentAfter(line: "s = '#':") == "    ")
    }

    @Test func dedentsAfterFlowStatements() {
        #expect(PythonIndent.indentAfter(line: "        return x") == "    ")
        #expect(PythonIndent.indentAfter(line: "    pass") == "")
        #expect(PythonIndent.indentAfter(line: "    returned = 1") == "    ")
    }

    @Test func backspaceWidths() {
        #expect(PythonIndent.dedentWidth(column: 8) == 4)
        #expect(PythonIndent.dedentWidth(column: 6) == 2)
        #expect(PythonIndent.dedentWidth(column: 0) == 0)
    }
}

@Suite struct IdentifierTests {
    @Test func findsPrefixAndWords() {
        let text = "\tos.getc x1 42" as NSString
        #expect(Identifier.prefixStart(in: text, before: 8) == 4)  // "getc"
        #expect(Identifier.prefixStart(in: text, before: 4) == 4)  // right after "."
        #expect(Identifier.wordRange(in: text, at: 2) == NSRange(location: 1, length: 2))  // "os"
        #expect(Identifier.wordRange(in: text, at: 3) == nil)  // "."
        #expect(Identifier.wordRange(in: text, at: 10) == NSRange(location: 9, length: 2))  // "x1"
        #expect(Identifier.wordRange(in: text, at: 12) == nil)  // number literal
    }
}

@Suite struct EnvironmentTests {
    @Test func prefersProjectVirtualenv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-env-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let python = bin.appendingPathComponent("python")
        try "#!/bin/sh\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try "home = /usr/bin\n".write(to: dir.appendingPathComponent(".venv/pyvenv.cfg"), atomically: true, encoding: .utf8)

        #expect(PythonEnvironment.interpreter(for: dir, environment: [:]) == python)
        #expect(PythonEnvironment.virtualEnvRoot(of: python)?.lastPathComponent == ".venv")
        let env = ToolLocator.environment(interpreter: python, base: ["PATH": "/usr/bin"])
        #expect(env["VIRTUAL_ENV"] == dir.appendingPathComponent(".venv").path)
        #expect(env["PATH"]?.hasPrefix(bin.path + ":") == true)
        #expect(env["PYTHONUNBUFFERED"] == "1")
    }

    @Test func answersPyrightConfiguration() {
        let result = LanguageServerSpec.configuration(
            items: [["section": "python"], ["section": "python.analysis"], ["section": "editor"]],
            pythonPath: "/p/bin/python")
        #expect(result[0]?["pythonPath"]?.stringValue == "/p/bin/python")
        #expect(result[1]?["useLibraryCodeForTypes"]?.boolValue == true)
        #expect(result[2] == .null)
    }
}

// MARK: - End-to-end (skipped when no Python language server is installed)

let hasPythonServer = LanguageServerSpec.locate(interpreter: nil) != nil

/// Starts the first Python language server found (basedpyright, pyright, pylsp or jedi).
func startPythonServer(in dir: URL) async throws -> LSPClient {
    let interpreter = PythonEnvironment.interpreter(for: dir)
    let (spec, url) = try #require(LanguageServerSpec.locate(interpreter: interpreter))
    let pythonPath = interpreter?.path
    let client = LSPClient()
    client.configurationProvider = { LanguageServerSpec.configuration(items: $0, pythonPath: pythonPath) }
    try client.start(executable: url, arguments: spec.arguments, environment: ToolLocator.environment(), currentDirectory: dir)
    _ = try await client.request("initialize", params: [
        "processId": .int(Int(getpid())),
        "rootUri": .string(dir.absoluteString),
        "workspaceFolders": [["uri": .string(dir.absoluteString), "name": "t"]],
        "capabilities": ["textDocument": ["hover": ["contentFormat": ["markdown"]],
                                          "documentSymbol": ["hierarchicalDocumentSymbolSupport": true]],
                         "workspace": ["configuration": true, "workspaceFolders": true]],
    ])
    try client.notify("initialized", params: [:])
    return client
}

private func makeProject(_ source: String) throws -> (dir: URL, file: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.py")
    try source.write(to: file, atomically: true, encoding: .utf8)
    return (dir, file)
}

@Suite struct LanguageServerIntegrationTests {
    @Test(.enabled(if: hasPythonServer), .timeLimit(.minutes(1)))
    func publishesDiagnosticsForBrokenCode() async throws {
        let source = "def main():\n    undefined_thing()\n"
        let (dir, file) = try makeProject(source)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (stream, continuation) = AsyncStream<[Diagnostic]>.makeStream()
        let client = try await startPythonServer(in: dir)
        client.onNotification = { method, params in
            if method == "textDocument/publishDiagnostics",
               let published = Diagnostic.parsePublish(params), !published.diagnostics.isEmpty {
                continuation.yield(published.diagnostics)
            }
        }
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "python", "version": 1, "text": .string(source)],
        ])

        var iterator = stream.makeAsyncIterator()
        let diagnostics = try #require(await iterator.next())
        #expect(diagnostics.contains { $0.message.contains("undefined_thing") && $0.start.line == 1 })
        await client.shutdown()
    }

    static let source = """
        import os


        def helper() -> int:
            return 1


        def main():
            print(helper())
            os.getc
        """

    @Test(.enabled(if: hasPythonServer), .timeLimit(.minutes(1)))
    func completionHoverAndDefinition() async throws {
        let (dir, file) = try makeProject(Self.source)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = try await startPythonServer(in: dir)
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "python", "version": 1,
                             "text": .string(Self.source)],
        ])
        func at(_ line: Int, _ character: Int) -> JSONValue {
            ["textDocument": ["uri": .string(file.absoluteString)],
             "position": TextPosition(line: line, character: character).json]
        }

        // `    os.getc|` on line 9
        let items = CompletionItem.parseList(try await client.request("textDocument/completion", params: at(9, 11)))
        #expect(items.contains { $0.label == "getcwd" && $0.insertText == "getcwd" },
                "items: \(items.prefix(10).map(\.label))")

        // Hover on the `helper` call (line 8)
        let hover = HoverContent.parse(try await client.request("textDocument/hover", params: at(8, 12)))
        #expect(hover?.contains("helper() -> int") == true, "hover was: \(hover ?? "nil")")

        // Definition of `helper` -> line 3
        let locations = Location.parseAll(try await client.request("textDocument/definition", params: at(8, 12)))
        #expect(locations.first?.uri.hasSuffix("/main.py") == true)
        #expect(locations.first?.start.line == 3)

        // Definition of `print` -> the builtins stub
        let stub = Location.parseAll(try await client.request("textDocument/definition", params: at(8, 5)))
        #expect(stub.first?.uri.hasSuffix("builtins.pyi") == true, "got \(stub)")

        await client.shutdown()
    }
}
