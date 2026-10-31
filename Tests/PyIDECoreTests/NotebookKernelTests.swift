import Foundation
import Testing
@testable import PyIDECore

@Suite struct NotebookJSONTests {
    /// Must match `json.dumps(nb, sort_keys=True, indent=1, ensure_ascii=False)` byte for byte.
    @Test(.enabled(if: PythonEnvironment.interpreter(for: nil) != nil))
    func matchesPythonsJupyterFormatting() throws {
        let python = try #require(PythonEnvironment.interpreter(for: nil))
        let script = #"""
            import json, sys
            nb = {"cells": [{"cell_type": "code", "source": ["x = 1\n", "print('h\u00e9llo \"q\"\t')"],
                   "outputs": [], "metadata": {}, "execution_count": None}],
                  "metadata": {"kernelspec": {"name": "python3"}, "ratio": 0.5, "flag": True},
                  "nbformat": 4, "nbformat_minor": 5, "empty": {}, "list": []}
            sys.stdout.write(json.dumps(nb, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
            """#
        let p = Process()
        p.executableURL = python
        p.arguments = ["-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let expected = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(expected.utf8))
        #expect(parsed.notebookJSON() == expected)
    }

    @Test func splitsSourceIntoLines() {
        #expect(Notebook.sourceLines("a\nb\n") == ["a\n", "b\n"])
        #expect(Notebook.sourceLines("a\nb") == ["a\n", "b"])
        #expect(Notebook.sourceLines("") == [])
    }
}

@Suite struct NotebookKernelTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [NotebookKernel.Event] = []
        func add(_ e: NotebookKernel.Event) { lock.withLock { items.append(e) } }
        var all: [NotebookKernel.Event] { lock.withLock { items } }
        func outputs(_ run: Int) -> [JSONValue] {
            all.compactMap { if case .output(run, let o) = $0 { o } else { nil } }
        }
        func done(_ run: Int) -> Int? {
            all.compactMap { if case .done(run, let n) = $0 { n } else { nil } }.first
        }
        var inputRequested: Bool { all.contains { if case .inputRequest = $0 { true } else { false } } }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test(.enabled(if: PythonEnvironment.interpreter(for: nil) != nil), .timeLimit(.minutes(1)))
    func emitsRichMimeBundles() async throws {
        let kernel = NotebookKernel()
        let events = Events()
        kernel.onEvent = { events.add($0) }
        try kernel.start(interpreter: try #require(PythonEnvironment.interpreter(for: nil)),
                         environment: ToolLocator.environment(), currentDirectory: nil)
        defer { kernel.stop() }

        let run = kernel.execute(#"""
            class Table:
                def _repr_html_(self): return "<table><tr><td>1</td></tr></table>"
                def _repr_latex_(self): return ("$x^2$", {})
                def __repr__(self): return "Table()"
            class Weird:
                def __getattr__(self, name): return lambda *a, **k: object()  # not a valid repr
            display(Table(), Weird())
            Table
            Table()
            """#)
        try await wait { events.done(run) != nil }
        let outputs = events.outputs(run)
        let displayed = outputs.filter { $0["output_type"] == "display_data" }
        #expect(displayed.count == 2)
        #expect(displayed.first?["data"]?["text/html"] == "<table><tr><td>1</td></tr></table>")
        #expect(displayed.first?["data"]?["text/latex"] == "$x^2$")
        #expect(displayed.last?["data"]?.objectValue?.keys.sorted() == ["text/plain"])
        let result = try #require(outputs.first { $0["output_type"] == "execute_result" })
        #expect(result["data"]?["text/plain"] == "Table()")
        #expect(result["data"]?["text/html"] != nil)
    }

    @Test(.enabled(if: PythonEnvironment.interpreter(for: nil) != nil), .timeLimit(.minutes(1)))
    func runsCellsInOneNamespace() async throws {
        let kernel = NotebookKernel()
        let events = Events()
        kernel.onEvent = { events.add($0) }
        try kernel.start(interpreter: try #require(PythonEnvironment.interpreter(for: nil)),
                         environment: ToolLocator.environment(), currentDirectory: nil)
        defer { kernel.stop() }

        let first = kernel.execute("x = 20\nprint('hi')\nx + 1")
        try await wait { events.done(first) != nil }
        #expect(events.done(first) == 1)
        let outputs = events.outputs(first)
        #expect(outputs.contains { $0["output_type"] == "stream" && $0["text"] == "hi" })
        #expect(outputs.contains { $0["output_type"] == "execute_result" && $0["data"]?["text/plain"] == "21" })

        let second = kernel.execute("1 / (x - 20)")
        try await wait { events.done(second) != nil }
        let error = try #require(events.outputs(second).first { $0["output_type"] == "error" })
        #expect(error["ename"] == "ZeroDivisionError")
        #expect(error["traceback"]?.arrayValue?.contains { $0.stringValue?.contains("<cell>") == true } == true)

        // input() asks the IDE; interrupt stops a long cell and the kernel keeps its state.
        let third = kernel.execute("name = input('Who? ')\nname.upper()")
        try await wait { events.inputRequested }
        kernel.sendInput("ada")
        try await wait { events.done(third) != nil }
        #expect(events.outputs(third).contains { $0["data"]?["text/plain"] == "'ADA'" })

        let fourth = kernel.execute("import time\ntime.sleep(30)")
        try await Task.sleep(for: .milliseconds(400))
        kernel.interrupt()
        try await wait { events.done(fourth) != nil }
        #expect(events.outputs(fourth).contains { $0["ename"] == "KeyboardInterrupt" })
        let fifth = kernel.execute("x")
        try await wait { events.done(fifth) != nil }
        #expect(events.outputs(fifth).contains { $0["data"]?["text/plain"] == "20" })
        #expect(events.done(fifth) == 5)
    }
}
