import Foundation
import Testing
@testable import PyIDECore

@Suite struct NotebookTests {
    static let sample = #"""
    {
     "cells": [
      {"cell_type": "markdown", "metadata": {}, "source": ["# Title\n", "Some *text*."]},
      {"cell_type": "code", "execution_count": 3, "metadata": {},
       "source": "print('hi')\n1 + 1",
       "outputs": [
         {"output_type": "stream", "name": "stdout", "text": ["hi\n"]},
         {"output_type": "execute_result", "execution_count": 3, "data": {"text/plain": ["2"]}, "metadata": {}},
         {"output_type": "display_data", "data": {"image/png": "iVBORw0KGgo=\n", "text/plain": ["<Figure>"]}, "metadata": {}}
       ]},
      {"cell_type": "code", "execution_count": null, "metadata": {}, "source": [], "outputs": [
         {"output_type": "error", "ename": "ZeroDivisionError", "evalue": "division by zero",
          "traceback": ["\u001b[0;31mZeroDivisionError\u001b[0m: division by zero"]}
      ]}
     ],
     "metadata": {"kernelspec": {"language": "python", "name": "python3"}},
     "nbformat": 4, "nbformat_minor": 5
    }
    """#

    @Test func parsesCellsAndOutputs() throws {
        let notebook = try Notebook.parse(Self.sample)
        #expect(notebook.language == "python")
        #expect(notebook.cells.map(\.kind) == [.markdown, .code, .code])
        #expect(notebook.cells[0].source == "# Title\nSome *text*.")
        #expect(notebook.cells[1].executionCount == 3 && notebook.cells[2].executionCount == nil)
        let outputs = notebook.cells[1].outputs
        #expect(outputs.count == 3)
        #expect(outputs[0] == .text("hi\n", isError: false))
        #expect(outputs[1] == .text("2", isError: false))
        if case .image(let data) = outputs[2] { #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])) } else {
            Issue.record("expected image, got \(outputs[2])")
        }
        #expect(notebook.cells[2].outputs == [.error(name: "ZeroDivisionError", value: "division by zero",
                                                     traceback: "ZeroDivisionError: division by zero")])
    }

    @Test func rejectsNonNotebooks() {
        #expect(throws: Notebook.ParseError.self) { try Notebook.parse("{\"a\": 1}") }
        #expect(throws: Notebook.ParseError.self) { try Notebook.parse("not json") }
    }
}
