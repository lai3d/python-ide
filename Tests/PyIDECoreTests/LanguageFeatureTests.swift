import Foundation
import Testing
@testable import PyIDECore

@Suite struct CompletionParsingTests {
    @Test func parsesCompletionListSortedBySortText() {
        let result: JSONValue = ["isIncomplete": false, "items": [
            ["label": "Printf", "kind": 3, "sortText": "00001", "detail": "func(format string, a ...any)"],
            ["label": "Println", "kind": 3, "sortText": "00000",
             "textEdit": ["range": ["start": ["line": 8, "character": 5], "end": ["line": 8, "character": 8]],
                          "newText": "Println"],
             "documentation": ["kind": "markdown", "value": "Println formats…"]],
        ]]
        let items = CompletionItem.parseList(result)
        #expect(items.map(\.label) == ["Println", "Printf"])
        #expect(items[0].kind == .function)
        #expect(items[0].documentation == "Println formats…")
        #expect(items[1].detail == "func(format string, a ...any)")
    }

    @Test func parsesBareArrayAndAdditionalEdits() {
        let result: JSONValue = [[
            "label": "strings", "kind": 9, "insertText": "strings",
            "additionalTextEdits": [["range": ["start": ["line": 2, "character": 0], "end": ["line": 2, "character": 0]],
                                     "newText": "import \"strings\"\n"]],
        ]]
        let item = try! #require(CompletionItem.parseList(result).first)
        #expect(item.kind == .module)
        #expect(item.additionalEdits == [TextEdit(start: TextPosition(line: 2, character: 0),
                                                  end: TextPosition(line: 2, character: 0),
                                                  newText: "import \"strings\"\n")])
    }

    @Test func stripsSnippets() {
        #expect(CompletionItem.stripSnippet("Foo(${1:a}, ${2:b})$0") == "Foo(a, b)")
        #expect(CompletionItem.parse(["label": "x", "insertText": "x($1)", "insertTextFormat": 2])?.insertText == "x()")
    }

    @Test func fuzzyMatches() {
        #expect(FuzzyMatch.matches("", "anything"))
        #expect(FuzzyMatch.matches("prl", "Println"))
        #expect(FuzzyMatch.matches("Pri", "Printf"))
        #expect(!FuzzyMatch.matches("ln", "Println"))  // first letter must match
        #expect(!FuzzyMatch.matches("Pz", "Println"))
    }
}

@Suite struct HoverAndLocationTests {
    @Test func parsesMarkupHover() {
        let result: JSONValue = ["contents": ["kind": "markdown", "value": "```go\nfunc Println(a ...any)\n```\n\nPrintln formats."]]
        let markdown = HoverContent.parse(result)
        #expect(markdown?.hasPrefix("```go") == true)
        let blocks = MarkdownBlock.parse(markdown!)
        #expect(blocks == [MarkdownBlock(kind: .code, text: "func Println(a ...any)"),
                           MarkdownBlock(kind: .text, text: "Println formats.")])
    }

    @Test func treatsHorizontalRulesAsSeparators() {
        let blocks = MarkdownBlock.parse("```go\nfunc F()\n```\n\n---\n\nDocs here.\n\n---\n\n[link](https://pkg.go.dev)")
        #expect(blocks.map(\.text) == ["func F()", "Docs here.", "[link](https://pkg.go.dev)"])
    }

    @Test func parsesMarkedStringArrays() {
        let result: JSONValue = ["contents": [["language": "go", "value": "var x int"], "doc"]]
        #expect(HoverContent.parse(result) == "```go\nvar x int\n```\n\ndoc")
        #expect(HoverContent.parse(["contents": ""]) == nil)
    }

    @Test func parsesLocationsAndLinks() {
        let range: JSONValue = ["start": ["line": 4, "character": 5], "end": ["line": 4, "character": 11]]
        #expect(Location.parseAll(["uri": "file:///a.py", "range": range]).map(\.uri) == ["file:///a.py"])
        let links = Location.parseAll([["targetUri": "file:///b.py", "targetRange": range, "targetSelectionRange": range]])
        #expect(links == [Location(uri: "file:///b.py", start: TextPosition(line: 4, character: 5),
                                   end: TextPosition(line: 4, character: 11))])
        #expect(Location.parseAll(.null).isEmpty)
    }
}
