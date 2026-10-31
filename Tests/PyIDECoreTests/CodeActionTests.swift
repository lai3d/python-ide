import Foundation
import Testing
@testable import PyIDECore

@Suite struct CodeActionTests {
    @Test func parsesRuffStyleActions() {
        let range: JSONValue = ["start": ["line": 0, "character": 0], "end": ["line": 1, "character": 0]]
        let actions = CodeAction.parseAll([
            ["title": "Ruff (F401): Remove unused import: `sys`", "kind": "quickfix", "isPreferred": true,
             "edit": ["changes": ["file:///x.py": [["range": range, "newText": ""]]]]],
            ["title": "Ruff: Fix all auto-fixable problems", "kind": "source.fixAll.ruff",
             "edit": ["changes": ["file:///x.py": []]]],
            ["title": "Run something", "command": "server.run", "arguments": []],
        ])
        #expect(actions.map(\.title) == ["Ruff (F401): Remove unused import: `sys`", "Ruff: Fix all auto-fixable problems"])
        #expect(actions[0].isQuickFix && actions[0].isPreferred && !actions[1].isQuickFix)
        #expect(actions[0].edit?["file:///x.py"]?.first?.newText == "")
    }

    @Test func keepsRawDiagnosticAndCode() throws {
        let raw: JSONValue = ["range": ["start": ["line": 0, "character": 7], "end": ["line": 0, "character": 10]],
                              "severity": 2, "code": "F401", "source": "Ruff",
                              "message": "`sys` imported but unused\n\nhelp: Remove unused import", "data": ["fix": true]]
        let diagnostic = try #require(Diagnostic.parse(raw))
        #expect(diagnostic.code == "F401" && diagnostic.raw == raw)
        #expect(diagnostic.summary == "`sys` imported but unused")
    }

    /// Talks to a real `ruff server`: diagnostics arrive with fixes attached, and codeAction returns them.
    @Test(.enabled(if: ToolLocator.find("ruff") != nil), .timeLimit(.minutes(1)))
    func ruffServerQuickFix() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-ruff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.py")
        let source = "import sys\nimport os\n\nprint(os.sep)\n"
        try source.write(to: file, atomically: true, encoding: .utf8)

        let (stream, continuation) = AsyncStream<[Diagnostic]>.makeStream()
        let client = LSPClient()
        client.onNotification = { method, params in
            if method == "textDocument/publishDiagnostics", let p = Diagnostic.parsePublish(params), !p.diagnostics.isEmpty {
                continuation.yield(p.diagnostics)
            }
        }
        try client.start(executable: try #require(ToolLocator.find("ruff")), arguments: ["server"],
                         environment: ToolLocator.environment(), currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())), "rootUri": .string(dir.absoluteString),
            "capabilities": ["textDocument": ["codeAction": ["codeActionLiteralSupport": [
                "codeActionKind": ["valueSet": ["quickfix", "source"]]]]]],
        ])
        try client.notify("initialized", params: [:])
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "python", "version": 1, "text": .string(source)],
        ])
        var iterator = stream.makeAsyncIterator()
        let diagnostics = try #require(await iterator.next())
        let unused = try #require(diagnostics.first { $0.code == "F401" })
        let result = try await client.request("textDocument/codeAction", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
            "range": ["start": unused.start.json, "end": unused.end.json],
            "context": ["diagnostics": [try #require(unused.raw)]],
        ])
        let fix = try #require(CodeAction.parseAll(result).first { $0.isPreferred && $0.isQuickFix })
        let edits = try #require(fix.edit?[file.absoluteString])
        #expect(TextEdit.apply(edits, to: source) == "import os\n\nprint(os.sep)\n")
        await client.shutdown()
    }
}
