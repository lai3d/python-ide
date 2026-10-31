import Foundation
import Testing
@testable import PyIDE
@testable import PyIDECore

/// Exercises the real wiring: Workspace → NotebookKernel → NotebookModel → saved .ipynb.
@MainActor
@Suite(.serialized) struct WorkspaceNotebookTests {
    static let notebook = """
        {"cells": [
          {"cell_type": "markdown", "id": "m", "metadata": {}, "source": ["# Test"]},
          {"cell_type": "code", "id": "a", "metadata": {}, "execution_count": null, "outputs": [],
           "source": ["total = sum(range(5))\\n", "print('total is', total)\\n", "total * 2"]},
          {"cell_type": "code", "id": "b", "metadata": {}, "execution_count": null, "outputs": [],
           "source": ["total / 0"]}
         ],
         "metadata": {"kernelspec": {"language": "python", "name": "python3"}},
         "nbformat": 4, "nbformat_minor": 5}
        """

    private func waitUntil(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test(.enabled(if: PythonEnvironment.interpreter(for: nil) != nil), .timeLimit(.minutes(1)))
    func runAllCellsAndSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.ipynb")
        try Self.notebook.write(to: file, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        #expect(workspace.isNotebook, "the only file, a notebook, should open")
        guard case .success(let model)? = workspace.notebookModel() else {
            Issue.record("notebook did not load")
            return
        }

        workspace.runAllCells(in: model)
        try await waitUntil { model.cells.filter { $0.kind == .code }.allSatisfy { $0.executionCount != nil } }
        let first = model.cells[1], second = model.cells[2]
        #expect(first.executionCount == 1 && second.executionCount == 2)
        #expect(first.outputs.contains { $0["output_type"] == "stream" && $0["text"]?.stringValue == "total is 10\n" },
                "outputs: \(first.outputs)")
        #expect(first.outputs.contains { $0["data"]?["text/plain"] == "20" })
        #expect(second.outputs.first?["ename"] == "ZeroDivisionError")
        #expect(model.kernelStatus == .idle)
        try await waitUntil { workspace.isDirty }  // written back to the document after a short debounce
        #expect(workspace.isDirty)

        workspace.save()
        try await waitUntil { !workspace.isDirty }
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(saved["cells"]?[1]?["execution_count"] == 1)
        #expect(saved["cells"]?[1]?["outputs"]?[0]?["text"] == ["total is 10\n"])
        #expect(saved["cells"]?[2]?["outputs"]?[0]?["ename"] == "ZeroDivisionError")

        // Restart clears the namespace: `total` is gone in the new kernel.
        workspace.restartKernel(for: model)
        let probe = model.insertCell(.code, after: model.cells.last?.id)
        model.setSource("'total' in globals()", of: probe)
        workspace.runCells([probe], in: model)
        try await waitUntil { model.cells.last?.executionCount != nil }
        #expect(model.cells.last?.outputs.first?["data"]?["text/plain"] == "False")
    }
}

@MainActor
@Suite(.serialized) struct WorkspaceNotebookCompletionTests {
    private func waitUntil(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test(.enabled(if: LanguageServerSpec.locate(interpreter: nil) != nil), .timeLimit(.minutes(1)))
    func completesUsingEarlierCells() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            {"cells": [
              {"cell_type": "code", "id": "a", "metadata": {}, "execution_count": null, "outputs": [],
               "source": ["%matplotlib inline\\n", "import math\\n", "def helper_fn(): pass"]},
              {"cell_type": "markdown", "id": "m", "metadata": {}, "source": ["notes"]},
              {"cell_type": "code", "id": "b", "metadata": {}, "execution_count": null, "outputs": [],
               "source": ["math.sq"]}
             ],
             "metadata": {}, "nbformat": 4, "nbformat_minor": 5}
            """.write(to: dir.appendingPathComponent("t.ipynb"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        guard case .success(let model)? = workspace.notebookModel() else {
            Issue.record("notebook did not load")
            return
        }
        let cell = model.cells[2]
        let items = await workspace.notebookCompletions(in: model, cell: cell.id, offset: (cell.source as NSString).length)
        #expect(items.contains { $0.label == "sqrt" }, "items: \(items.prefix(8).map(\.label))")

        // Edit the cell: names defined in the first cell complete too (the virtual doc is updated).
        model.setSource("help", of: cell.id)
        let again = await workspace.notebookCompletions(in: model, cell: cell.id, offset: 4)
        #expect(again.contains { $0.label == "helper_fn" }, "items: \(again.prefix(8).map(\.label))")
        // The virtual document never shows up as a problem.
        #expect(workspace.allProblems.allSatisfy { !$0.path.hasSuffix(".pyide.py") })
    }

    @Test(.enabled(if: LanguageServerSpec.locate(interpreter: nil) != nil), .timeLimit(.minutes(1)))
    func showsDiagnosticsAndHoverInCells() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            {"cells": [
              {"cell_type": "code", "id": "a", "metadata": {}, "execution_count": null, "outputs": [],
               "source": ["import math\\n", "x = 1"]},
              {"cell_type": "markdown", "id": "m", "metadata": {}, "source": ["notes"]},
              {"cell_type": "code", "id": "b", "metadata": {}, "execution_count": null, "outputs": [],
               "source": ["print(undefined_name)\\n", "math.sqrt(x)"]}
             ],
             "metadata": {}, "nbformat": 4, "nbformat_minor": 5}
            """.write(to: dir.appendingPathComponent("t.ipynb"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        guard case .success(let model)? = workspace.notebookModel() else {
            Issue.record("notebook did not load")
            return
        }
        let cell = model.cells[2]
        try await waitUntil { !(model.cellDiagnostics[cell.id] ?? []).isEmpty }
        let problems = model.cellDiagnostics[cell.id] ?? []
        // Only the undefined name: `math`/`x` come from the first cell, and the trailing
        // expression (the cell's output) isn't flagged.
        #expect(problems.count == 1, "\(problems.map(\.message))")
        #expect(problems.first?.start == TextPosition(line: 0, character: 6))
        #expect(model.cellDiagnostics[model.cells[0].id] == nil)

        let hover = await workspace.notebookHover(in: model, cell: cell.id, offset: 28)  // on `sqrt`
        #expect(hover?.contains("sqrt") == true, "hover: \(hover ?? "nil")")

        // Fixing the cell clears its problem once the server re-checks.
        model.setSource("print(x)\nmath.sqrt(x)", of: cell.id)
        try await waitUntil { (model.cellDiagnostics[cell.id] ?? []).isEmpty }
        #expect((model.cellDiagnostics[cell.id] ?? []).isEmpty)
        #expect(workspace.allProblems.allSatisfy { !$0.path.hasSuffix(".pyide.py") })
    }
}
