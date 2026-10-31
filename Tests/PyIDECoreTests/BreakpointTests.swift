import Foundation
import Testing
@testable import PyIDECore

@Suite struct LineShiftTests {
    let text = "a = 1\nb = 2\nc = 3\nd = 4\n"  // lines 0..3

    private func map(_ new: String, _ lines: [Int]) -> [Int?] {
        let m = LineShift.mapper(old: text, new: new)
        return lines.map(m)
    }

    @Test func insertingLineAboveShiftsDown() {
        // Enter at column 0 of line 1 (before "b = 2").
        #expect(map("a = 1\n\nb = 2\nc = 3\nd = 4\n", [0, 1, 2, 3]) == [0, 2, 3, 4])
        // Enter at end of line 0.
        #expect(map("a = 1\n\nb = 2\nc = 3\nd = 4\n", [0]) == [0])
        // Pasting two lines at the top.
        #expect(map("x\ny\n" + text, [0, 3]) == [2, 5])
    }

    @Test func deletingLinesRemovesAndShiftsUp() {
        // Delete line 1 entirely.
        #expect(map("a = 1\nc = 3\nd = 4\n", [0, 1, 2, 3]) == [0, nil, 1, 2])
        // Backspace at start of line 2 joins it onto line 1.
        #expect(map("a = 1\nb = 2c = 3\nd = 4\n", [1, 2, 3]) == [1, nil, 2])
    }

    @Test func editsWithinALineChangeNothing() {
        #expect(map("a = 1\nb = 22\nc = 3\nd = 4\n", [0, 1, 2, 3]) == [0, 1, 2, 3])
        #expect(map(text, [2]) == [2])
    }

    @Test func remapsDictionaries() {
        let moved = LineShift.remap([1: "x > 0", 3: ""], old: text, new: "new\n" + text)
        #expect(moved == [2: "x > 0", 4: ""])
    }

    @Test func encodesConditions() {
        #expect(SourceBreakpoint(line: 3).json == ["line": 3])
        #expect(SourceBreakpoint(line: 3, condition: "i == 2").json == ["line": 3, "condition": "i == 2"])
        #expect(SourceBreakpoint(line: 4, spec: BreakpointSpec(logMessage: "i={i}")).json == ["line": 4, "logMessage": "i={i}"])
        #expect(SourceBreakpoint(line: 4, spec: BreakpointSpec()).json == ["line": 4])
    }
}
