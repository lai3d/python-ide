import Foundation
import Testing
@testable import PyIDECore

@Suite struct REPLPrepareTests {
    @Test func dedentsAndClosesBlocks() {
        let selection = "    def f(x):\n        y = x\n\n        return y\n"
        #expect(PythonREPL.prepareForSending(selection) == "def f(x):\n    y = x\n    return y\n\n")
    }

    @Test func keepsTopLevelBlankLinesAndSimpleStatements() {
        #expect(PythonREPL.prepareForSending("a = 1\n\nb = 2\n\n\n") == "a = 1\n\nb = 2\n")
        #expect(PythonREPL.prepareForSending("   \n") == "")
    }
}

@Suite struct REPLSessionTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ s: String) { lock.withLock { text += s } }
        var value: String { lock.withLock { text } }
    }

    @Test(.enabled(if: PythonEnvironment.interpreter(for: nil) != nil), .timeLimit(.minutes(1)))
    func evaluatesAndInterrupts() async throws {
        let python = try #require(PythonEnvironment.interpreter(for: nil))
        let repl = PythonREPL()
        let output = Collector()
        repl.onOutput = { output.append($0) }
        try repl.start(interpreter: python, environment: ToolLocator.environment(), currentDirectory: nil)
        defer { repl.stop() }

        func waitFor(_ needle: String) async throws {
            for _ in 0..<100 {
                if output.value.contains(needle) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("timed out waiting for \(needle); got: \(output.value)")
        }

        repl.send("40 + 2")
        try await waitFor("42")
        repl.send(PythonREPL.prepareForSending("def sq(n):\n    return n * n\n"))
        repl.send("print('sq=%d' % sq(7))")
        try await waitFor("sq=49")

        repl.send("import time; time.sleep(30)")
        try await Task.sleep(for: .milliseconds(300))
        repl.interrupt()
        try await waitFor("KeyboardInterrupt")
        repl.send("print('alive')")
        try await waitFor("alive")
    }
}
