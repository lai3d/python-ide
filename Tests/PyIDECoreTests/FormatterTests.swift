import Foundation
import Testing
@testable import PyIDECore

@Suite struct CodeFormatterTests {
    /// A stand-in formatter: uppercases stdin, or fails on the word "bad".
    private func fakeFormatter() throws -> (CodeFormatter, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-fmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("ruff")
        try """
            #!/bin/sh
            input=$(cat)
            case "$input" in *bad*) echo "error: Failed to parse $3:1:1" >&2; exit 2;; esac
            printf '%s\\n' "$input" | tr a-z A-Z
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (CodeFormatter(kind: .ruff, executable: script), dir)
    }

    @Test func pipesSourceThroughTool() async throws {
        let (formatter, dir) = try fakeFormatter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.py")
        #expect(formatter.arguments(for: file) == ["format", "--stdin-filename", file.path, "-"])
        #expect(CodeFormatter(kind: .black, executable: file).arguments(for: file, operation: .fixAll) == nil)
        let big = String(repeating: "x = 1\n", count: 50_000)  // larger than a pipe buffer
        let out = try await formatter.format(big, file: file, environment: [:], currentDirectory: dir)
        #expect(out.count == big.count)
        #expect(out.hasPrefix("X = 1\n"))
    }

    @Test func reportsToolErrors() async throws {
        let (formatter, dir) = try fakeFormatter()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CodeFormatter.Failure.self) {
            try await formatter.format("bad", file: dir.appendingPathComponent("x.py"), environment: [:], currentDirectory: dir)
        }
        do {
            _ = try await formatter.format("bad", file: dir.appendingPathComponent("x.py"), environment: [:], currentDirectory: dir)
        } catch {
            #expect(error.localizedDescription.hasPrefix("ruff: error: Failed to parse"))
        }
    }

    @Test(.enabled(if: ToolLocator.find("ruff") != nil), .timeLimit(.minutes(1)))
    func formatsWithRealRuff() async throws {
        let formatter = try #require(CodeFormatter.locate(interpreter: nil))
        let dir = FileManager.default.temporaryDirectory
        let out = try await formatter.format("x = {  'a':1 }\ndef f( a ):\n  return a\n",
                                             file: dir.appendingPathComponent("t.py"),
                                             environment: ToolLocator.environment(), currentDirectory: dir)
        #expect(out == "x = {\"a\": 1}\n\n\ndef f(a):\n    return a\n")
    }

    @Test(.enabled(if: ToolLocator.find("ruff") != nil), .timeLimit(.minutes(1)))
    func fixesAndOrganizesImportsWithRealRuff() async throws {
        let formatter = try #require(CodeFormatter.locate(interpreter: nil))
        let dir = FileManager.default.temporaryDirectory
        let source = "import sys\nimport os\nprint(os.sep, undefined_name)\n"
        let env = ToolLocator.environment()
        let fixed = try await formatter.format(source, file: dir.appendingPathComponent("t.py"), operation: .fixAll,
                                               environment: env, currentDirectory: dir)
        #expect(fixed == "import os\n\nprint(os.sep, undefined_name)\n" || fixed == "import os\nprint(os.sep, undefined_name)\n",
                "fixed: \(fixed)")
        let organized = try await formatter.format(source, file: dir.appendingPathComponent("t.py"), operation: .organizeImports,
                                                   environment: env, currentDirectory: dir)
        #expect(organized.hasPrefix("import os\nimport sys\n"), "organized: \(organized)")
    }
}
