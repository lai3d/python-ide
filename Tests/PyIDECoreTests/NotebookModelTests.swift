import Foundation
import Testing
@testable import PyIDECore

@MainActor
@Suite struct NotebookModelTests {
    static let text = #"""
    {
     "cells": [
      {
       "cell_type": "markdown",
       "id": "m1",
       "metadata": {},
       "source": [
        "# Title"
       ]
      },
      {
       "cell_type": "code",
       "execution_count": 2,
       "id": "c1",
       "metadata": {
        "tags": [
         "keep"
        ]
       },
       "outputs": [
        {
         "name": "stdout",
         "output_type": "stream",
         "text": [
          "hi\n"
         ]
        }
       ],
       "source": [
        "print('hi')"
       ]
      }
     ],
     "metadata": {
      "kernelspec": {
       "language": "python",
       "name": "python3"
      }
     },
     "nbformat": 4,
     "nbformat_minor": 5
    }

    """#

    @Test func unchangedNotebookRoundTripsExactly() throws {
        let model = try NotebookModel(documentID: "x", text: Self.text)
        #expect(model.cells.count == 2 && model.cells[1].executionCount == 2)
        #expect(model.serialized() == Self.text)
    }

    @Test func editsRunsAndStructureChanges() throws {
        let model = try NotebookModel(documentID: "x", text: Self.text)
        var pushed: String?
        model.onSerialize = { pushed = $0 }
        let code = model.cells[1].id

        model.setSource("for i in range(2):\n    print(i)", of: code)
        model.markQueued(code)
        model.append(["output_type": "stream", "name": "stdout", "text": "0\n"], to: code)
        model.append(["output_type": "stream", "name": "stdout", "text": "1\n"], to: code)
        model.append(["output_type": "execute_result", "execution_count": 3, "metadata": [:],
                      "data": ["text/plain": "'done'"]], to: code)
        model.finish(code, executionCount: 3)
        #expect(model.cells[1].outputs.count == 2)  // the two stream chunks merged
        #expect(model.cells[1].state == .idle)

        let added = model.insertCell(.markdown, after: code)
        model.setSource("Some *notes*", of: added)
        model.moveCell(added, by: -1)
        model.flush()

        let json = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(pushed).utf8))
        let cells = try #require(json["cells"]?.arrayValue)
        #expect(cells.map { $0["cell_type"]?.stringValue } == ["markdown", "markdown", "code"])
        #expect(cells[1]["source"] == ["Some *notes*"])
        #expect(cells[1]["outputs"] == nil && cells[1]["id"]?.stringValue?.count == 8)
        let run = cells[2]
        #expect(run["source"] == ["for i in range(2):\n", "    print(i)"])
        #expect(run["execution_count"] == 3)
        #expect(run["metadata"]?["tags"] == ["keep"])  // cell metadata preserved
        #expect(run["outputs"]?[0]?["text"] == ["0\n", "1\n"])
        #expect(run["outputs"]?[1]?["data"]?["text/plain"] == ["'done'"])
        // Loading what we wrote gives the same notebook back.
        #expect(try NotebookModel(documentID: "x", text: pushed!).serialized() == pushed)
    }

    @Test func clearOutputsAndKindChanges() throws {
        let model = try NotebookModel(documentID: "x", text: Self.text)
        model.clearOutputs()
        #expect(model.cells[1].outputs.isEmpty && model.cells[1].executionCount == nil)
        model.setKind(.markdown, of: model.cells[1].id)
        model.deleteCell(model.cells[0].id)
        #expect(model.cells.map(\.kind) == [.markdown])
        model.deleteCell(model.cells[0].id)
        #expect(model.cells.count == 1 && model.cells[0].kind == .code)  // never empty
    }
}
