import Foundation
import Testing
@testable import PyIDE
@testable import PyIDECore

@MainActor
@Suite(.serialized) struct WorkspaceEditingTests {
    private func project(_ source: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("main.py")
        try source.write(to: file, atomically: true, encoding: .utf8)
        return (dir, file)
    }

    private func waitUntil(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test(.enabled(if: ToolLocator.find("ruff") != nil), .timeLimit(.minutes(1)))
    func formatOnSaveWritesFormattedFile() async throws {
        let (dir, file) = try project("x = 1\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        let previous = workspace.formatOnSave
        workspace.formatOnSave = true
        defer { workspace.formatOnSave = previous }
        await workspace.openFolder(dir)

        workspace.updateText("def f( a ):\n  return {  'a':a }\n")
        workspace.save()
        try await waitUntil { !workspace.isDirty }
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == "def f(a):\n    return {\"a\": a}\n")
        #expect(workspace.text == saved)
    }

    @Test(.enabled(if: ToolLocator.find("ruff") != nil), .timeLimit(.minutes(1)))
    func ruffQuickFixRemovesUnusedImport() async throws {
        let (dir, _) = try project("import sys\nimport os\n\nprint(os.sep)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        try await waitUntil { workspace.currentDiagnostics.contains { $0.code == "F401" } }
        #expect(workspace.currentDiagnostics.contains { $0.code == "F401" }, "ruff diagnostics never arrived")

        await workspace.showQuickFixes(at: 8)  // on `sys`
        let menu = try #require(workspace.quickFixMenu)
        #expect(menu.actions.first?.title.contains("Remove unused import") == true, "actions: \(menu.actions.map(\.title))")
        await workspace.apply(try #require(menu.actions.first))
        #expect(workspace.text == "import os\n\nprint(os.sep)\n")
        #expect(workspace.isDirty)
    }
}
