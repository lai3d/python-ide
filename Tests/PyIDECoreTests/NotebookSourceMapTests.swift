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
}
