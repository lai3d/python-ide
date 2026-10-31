import Foundation
import Testing
@testable import PyIDECore

@Suite struct LSPFramerTests {
    @Test func roundTripsSingleMessage() {
        var framer = LSPFramer()
        let body = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        #expect(framer.append(LSPFramer.frame(body)) == [body])
    }

    @Test func reassemblesSplitChunks() {
        var framer = LSPFramer()
        let body = Data(#"{"hello":"wörld"}"#.utf8)
        let framed = LSPFramer.frame(body)
        let mid = framed.count / 2
        #expect(framer.append(framed.prefix(mid)).isEmpty)
        #expect(framer.append(framed.suffix(from: mid)) == [body])
    }

    @Test func splitsMultipleMessagesInOneChunk() {
        var framer = LSPFramer()
        let a = Data("{}".utf8), b = Data("[1,2]".utf8)
        #expect(framer.append(LSPFramer.frame(a) + LSPFramer.frame(b)) == [a, b])
    }
}

@Suite struct JSONValueTests {
    @Test func roundTrips() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": 1.5]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded["a"]?.intValue == 1)
        #expect(decoded["b"]?[2]?.stringValue == "x")
    }
}

@Suite struct LineIndexTests {
    @Test func convertsPositions() {
        let index = LineIndex("ab\ncdef\n\ng")
        #expect(index.lineCount == 4)
        #expect(index.offset(of: TextPosition(line: 1, character: 2)) == 5)
        #expect(index.offset(of: TextPosition(line: 1, character: 99)) == 7)  // clamped before newline
        #expect(index.position(of: 5) == TextPosition(line: 1, character: 2))
        #expect(index.position(of: 9) == TextPosition(line: 3, character: 0))
    }

    @Test func usesUTF16Units() {
        let index = LineIndex("x😀y")  // emoji is 2 UTF-16 units, like LSP's default encoding
        #expect(index.offset(of: TextPosition(line: 0, character: 3)) == 3)
        #expect(index.utf16Count == 4)
    }
}

@Suite struct DiagnosticTests {
    @Test func parsesPublishDiagnostics() throws {
        let params: JSONValue = [
            "uri": "file:///tmp/main.py",
            "diagnostics": [
                ["range": ["start": ["line": 3, "character": 1], "end": ["line": 3, "character": 5]],
                 "severity": 1, "message": "undefined: foo", "source": "compiler"],
                ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
                 "severity": 2, "message": "warn"],
            ],
        ]
        let result = try #require(Diagnostic.parsePublish(params))
        #expect(result.uri == "file:///tmp/main.py")
        #expect(result.diagnostics.map(\.message) == ["warn", "undefined: foo"])  // sorted by position
        #expect(result.diagnostics[1].severity == .error)
        #expect(result.diagnostics[1].start == TextPosition(line: 3, character: 1))
    }
}
