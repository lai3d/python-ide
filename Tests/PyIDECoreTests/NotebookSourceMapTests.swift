import Foundation
import Testing
@testable import PyIDECore

@Suite struct NotebookSourceMapTests {
    @Test func concatenatesCodeCellsAndMapsPositions() {
        let map = NotebookSourceMap(codeCells: [(1, "import math\nx = 1"), (3, "%matplotlib inline\nmath.sq")])
        #expect(map.text == "import math\nx = 1\n\n#matplotlib inline\nmath.sq\n\n")
        #expect(map.startLines == [1: 0, 3: 3])
        // Caret after `math.sq` in cell 3 (line 1, column 7).
        let source = "%matplotlib inline\nmath.sq"
        #expect(map.position(cell: 3, source: source, offset: (source as NSString).length) == TextPosition(line: 4, character: 7))
        #expect(map.position(cell: 2, source: "", offset: 0) == nil)
    }

    @Test func keepsIndentedMagicsInPlace() {
        #expect(NotebookSourceMap.neutralizeMagics("for i in r:\n    !echo hi") == "for i in r:\n    #echo hi")
    }

    @Test func mapsDiagnosticsBackToCells() {
        // Cell 0 → lines 0-1, separator 2; cell 2 → lines 3-4, separator 5.
        let map = NotebookSourceMap(codeCells: [(0, "import math\nx = 1"), (2, "print(y)\nx")])
        #expect(map.lineCounts == [0: 2, 2: 2])
        #expect(map.locate(line: 4)! == (2, 1))
        #expect(map.locate(line: 2) == nil)
        func diag(_ line: Int, _ c: Int, _ endLine: Int, _ endC: Int, code: String? = nil,
                  severity: Diagnostic.Severity = .error, message: String = "m") -> Diagnostic {
            Diagnostic(start: TextPosition(line: line, character: c), end: TextPosition(line: endLine, character: endC),
                       severity: severity, message: message, code: code)
        }
        let result = map.cellDiagnostics([
            diag(3, 6, 3, 7, code: "reportUndefinedVariable"),
            diag(4, 0, 4, 1, code: "reportUnusedExpression", severity: .warning),
            diag(1, 0, 1, 1, severity: .hint),
            diag(0, 0, 0, 5, message: "\"await\" allowed only within async function"),
            diag(1, 4, 9, 0),  // runs past the cell: clipped to its last line
        ])
        #expect(result[2]?.count == 1)
        #expect(result[2]?.first?.start == TextPosition(line: 0, character: 6))
        #expect(result[2]?.first?.code == "reportUndefinedVariable")
        #expect(result[0]?.count == 1)
        #expect(result[0]?.first?.end.line == 1)
    }
}
