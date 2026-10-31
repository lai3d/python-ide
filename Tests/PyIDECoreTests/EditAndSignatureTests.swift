import Foundation
import Testing
@testable import PyIDECore

@Suite struct TextEditApplyTests {
    private func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> TextEdit {
        TextEdit(start: TextPosition(line: l1, character: c1), end: TextPosition(line: l2, character: c2), newText: text)
    }

    @Test func appliesEditsAgainstOriginalPositions() {
        let text = "def helper():\n    return 1\n\nhelper()\nx = helper\n"
        let edits = [edit(0, 4, 0, 10, "assist"), edit(3, 0, 3, 6, "assist"), edit(4, 4, 4, 10, "assist")]
        #expect(TextEdit.apply(edits, to: text) == "def assist():\n    return 1\n\nassist()\nx = assist\n")
        #expect(TextEdit.apply(edits.reversed(), to: text) == TextEdit.apply(edits, to: text))  // order-independent
    }

    @Test func handlesInsertionsDeletionsAndUTF16() {
        #expect(TextEdit.apply([edit(0, 0, 0, 0, "import os\n")], to: "x\n") == "import os\nx\n")
        #expect(TextEdit.apply([edit(0, 3, 0, 4, "")], to: "😀ab") == "😀a")  // emoji is 2 UTF-16 units
    }

    @Test func parsesWorkspaceEditShapes() {
        let range: JSONValue = ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 10]]
        let changes = WorkspaceEdit.parse(["changes": ["file:///a.py": [["range": range, "newText": "b"]]]])
        #expect(changes["file:///a.py"]?.count == 1)
        let documentChanges = WorkspaceEdit.parse(["documentChanges": [
            ["textDocument": ["uri": "file:///a.py", "version": 3], "edits": [["range": range, "newText": "b"]]],
            ["kind": "rename", "oldUri": "file:///x.py", "newUri": "file:///y.py"],
        ]])
        #expect(Array(documentChanges.keys) == ["file:///a.py"])
    }
}

@Suite struct SignatureParsingTests {
    @Test func parsesOffsetAndStringParameterLabels() throws {
        let result: JSONValue = [
            "signatures": [[
                "label": "(a: int, b: str = \"x\") -> None",
                "documentation": ["kind": "markdown", "value": "Does things."],
                "parameters": [["label": [1, 7]], ["label": "b: str = \"x\""]],
                "activeParameter": 1,
            ]],
            "activeSignature": 0,
        ]
        let info = try #require(SignatureInfo.parse(result))
        let label = info.label as NSString
        #expect(label.substring(with: info.parameters[0]) == "a: int")
        #expect(label.substring(with: try #require(info.activeParameterRange)) == "b: str = \"x\"")
        #expect(info.documentation == "Does things.")
        #expect(info.overloadPosition == nil)
        #expect(SignatureInfo.parse(["signatures": []]) == nil)
        #expect(SignatureInfo.parse(.null) == nil)
    }

    @Test func validatesPythonNames() {
        #expect(Identifier.isValidPythonName("new_name2"))
        #expect(Identifier.isValidPythonName("_x"))
        #expect(!Identifier.isValidPythonName("2x"))
        #expect(!Identifier.isValidPythonName("class"))
        #expect(!Identifier.isValidPythonName("a-b"))
        #expect(!Identifier.isValidPythonName(""))
    }

    @Test func parsesPrepareRename() {
        let range: JSONValue = ["start": ["line": 2, "character": 4], "end": ["line": 2, "character": 10]]
        #expect(PrepareRename.parse(range)?.start == TextPosition(line: 2, character: 4))
        #expect(PrepareRename.parse(["range": range, "placeholder": "helper"])?.placeholder == "helper")
        #expect(PrepareRename.parse(.null) == nil)
    }
}

@Suite struct LanguageServerRefactorTests {
    static let source = """
        def helper(count: int, label: str = "x") -> int:
            return count


        def main():
            print(helper(1, ))
            return helper

        """

    @Test(.enabled(if: hasPythonServer), .timeLimit(.minutes(1)))
    func signatureReferencesAndRename() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.py")
        try Self.source.write(to: file, atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("other.py")
        let otherSource = "from main import helper\n\nhelper(2)\n"
        try otherSource.write(to: other, atomically: true, encoding: .utf8)

        let client = try await startPythonServer(in: dir)
        for (url, text) in [(file, Self.source), (other, otherSource)] {
            try client.notify("textDocument/didOpen", params: [
                "textDocument": ["uri": .string(url.absoluteString), "languageId": "python", "version": 1, "text": .string(text)],
            ])
        }
        func at(_ line: Int, _ character: Int) -> JSONValue {
            ["textDocument": ["uri": .string(file.absoluteString)],
             "position": TextPosition(line: line, character: character).json]
        }

        // `    print(helper(1, |))` — second parameter active
        let help = try await client.request("textDocument/signatureHelp", params: at(5, 20))
        let info = try #require(SignatureInfo.parse(help), "signatureHelp: \(help)")
        let active = (info.label as NSString).substring(with: try #require(info.activeParameterRange))
        #expect(active.hasPrefix("label"), "label: \(info.label), active: \(active)")

        // References to `helper` (definition line 0) across both files
        var refParams = at(0, 5)
        if case .object(var o) = refParams { o["context"] = ["includeDeclaration": true]; refParams = .object(o) }
        let refs = Location.parseAll(try await client.request("textDocument/references", params: refParams))
        #expect(refs.count >= 4, "refs: \(refs)")
        #expect(refs.contains { $0.uri.hasSuffix("/other.py") })

        // Rename `helper` -> `assist`
        let prepared = PrepareRename.parse(try await client.request("textDocument/prepareRename", params: at(0, 5)))
        #expect(prepared?.start == TextPosition(line: 0, character: 4))
        var renameParams = at(0, 5)
        if case .object(var o) = renameParams { o["newName"] = "assist"; renameParams = .object(o) }
        let edit = WorkspaceEdit.parse(try await client.request("textDocument/rename", params: renameParams))
        let mainEdits = try #require(edit.first { $0.key.hasSuffix("/main.py") }?.value)
        let renamed = TextEdit.apply(mainEdits, to: Self.source)
        #expect(renamed.contains("def assist(") && renamed.contains("print(assist(1, ))") && !renamed.contains("helper"))
        let otherEdits = try #require(edit.first { $0.key.hasSuffix("/other.py") }?.value)
        #expect(TextEdit.apply(otherEdits, to: otherSource) == "from main import assist\n\nassist(2)\n")

        await client.shutdown()
    }
}
