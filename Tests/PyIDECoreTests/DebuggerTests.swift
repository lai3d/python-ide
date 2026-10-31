import Foundation
import Testing
@testable import PyIDECore

@Suite struct DAPModelTests {
    @Test func parsesFramesAndVariables() {
        let frames = StackFrameInfo.parseAll(["stackFrames": [
            ["id": 3, "name": "square", "line": 2, "column": 1, "source": ["path": "/p/main.py"]],
            ["id": 4, "name": "<module>", "line": 5, "column": 1],
        ]])
        #expect(frames.map(\.name) == ["square", "<module>"])
        #expect(frames[0].path == "/p/main.py" && frames[1].path == nil)
        let vars = VariableInfo.parseAll(["variables": [
            ["name": "n", "value": "7", "type": "int", "variablesReference": 0],
            ["name": "items", "value": "[1, 2]", "type": "list", "variablesReference": 12],
        ]])
        #expect(vars.map(\.reference) == [0, 12])
        #expect(VariableInfo.parseAll(["scopes": [["name": "Locals", "variablesReference": 5, "expensive": false]]])
                .first?.reference == 5)
    }

    @Test func buildsAdapterEnvironmentAndInstallCommand() {
        let env = DebugpyLocator.adapterEnvironment(base: ["PYTHONPATH": "/x"], useSupportDirectory: true)
        #expect(env["PYTHONPATH"] == DebugpyLocator.supportDirectory.path + ":/x")
        let cmd = DebugpyLocator.installCommand(interpreter: URL(fileURLWithPath: "/usr/bin/python3"))
        #expect(cmd.arguments.contains("debugpy") && cmd.arguments.contains(DebugpyLocator.supportDirectory.path))
    }
}

/// Collects DAP events so the test can await specific ones.
final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, JSONValue)] = []

    func add(_ event: String, _ body: JSONValue) { lock.withLock { events.append((event, body)) } }

    var output: String {
        lock.withLock { events.filter { $0.0 == "output" }.compactMap { $0.1["output"]?.stringValue }.joined() }
    }

    /// Waits for the next unconsumed event named `name`, consuming it.
    func next(_ name: String, timeout: Duration = .seconds(20)) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let hit: JSONValue? = lock.withLock {
                guard let i = events.firstIndex(where: { $0.0 == name }) else { return nil }
                return events.remove(at: i).1
            }
            if let hit { return hit }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CancellationError()
    }
}

@Suite struct DebugpyIntegrationTests {
    static var canRun: Bool {
        PythonEnvironment.interpreter(for: nil) != nil && DebugpyLocator.isInstalledInSupportDirectory
    }

    @Test(.enabled(if: canRun), .timeLimit(.minutes(1)))
    func breakpointStackVariablesAndStepping() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-dbg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let program = dir.appendingPathComponent("main.py")
        try """
            def square(n):
                result = n * n
                return result


            values = [square(i) for i in range(3)]
            print("done", values)

            """.write(to: program, atomically: true, encoding: .utf8)

        let python = try #require(PythonEnvironment.interpreter(for: nil))
        let inbox = EventInbox()
        let client = DAPClient()
        client.onEvent = { inbox.add($0, $1) }
        try client.start(executable: python, arguments: ["-m", "debugpy.adapter"],
                         environment: DebugpyLocator.adapterEnvironment(base: ToolLocator.environment(), useSupportDirectory: true),
                         currentDirectory: dir)
        defer { client.terminate() }

        _ = try await client.request("initialize", arguments: [
            "clientID": "pyide", "adapterID": "debugpy", "linesStartAt1": true, "columnsStartAt1": true,
            "pathFormat": "path", "supportsRunInTerminalRequest": false,
        ])
        // debugpy answers `launch` only after configurationDone, so don't await it yet.
        let launch = Task {
            try await client.request("launch", arguments: [
                "program": .string(program.path), "cwd": .string(dir.path), "python": [.string(python.path)],
                "console": "internalConsole", "justMyCode": true,
            ])
        }
        _ = try await inbox.next("initialized")
        let set = try await client.request("setBreakpoints", arguments: [
            "source": ["path": .string(program.path)], "breakpoints": [["line": 2]],
        ])
        #expect(set["breakpoints"]?[0]?["verified"]?.boolValue == true, "setBreakpoints: \(set)")
        _ = try await client.request("setExceptionBreakpoints", arguments: ["filters": ["uncaught"]])
        _ = try await client.request("configurationDone")
        _ = try await launch.value

        // Hit the breakpoint in square(0).
        let stopped = try await inbox.next("stopped")
        #expect(stopped["reason"]?.stringValue == "breakpoint")
        let thread = try #require(stopped["threadId"]?.intValue)
        let frames = StackFrameInfo.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread)]))
        #expect(frames.first?.name == "square" && frames.first?.line == 2, "frames: \(frames)")
        let scopes = VariableInfo.parseAll(try await client.request("scopes", arguments: ["frameId": .int(frames[0].id)]))
        let locals = try #require(scopes.first)
        let vars = VariableInfo.parseAll(try await client.request("variables", arguments: ["variablesReference": .int(locals.reference)]))
        #expect(vars.contains { $0.name == "n" && $0.value == "0" }, "vars: \(vars)")

        // Step over line 2 -> line 3, where `result` exists.
        _ = try await client.request("next", arguments: ["threadId": .int(thread)])
        _ = try await inbox.next("stopped")
        let frames2 = StackFrameInfo.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread)]))
        #expect(frames2.first?.line == 3)

        // Evaluate in the paused frame.
        let evaluated = try await client.request("evaluate", arguments: [
            "expression": "n + 100", "frameId": .int(frames2[0].id), "context": "repl",
        ])
        #expect(evaluated["result"]?.stringValue == "100")

        // Clear breakpoints and run to completion.
        _ = try await client.request("setBreakpoints", arguments: ["source": ["path": .string(program.path)], "breakpoints": []])
        _ = try await client.request("continue", arguments: ["threadId": .int(thread)])
        _ = try await inbox.next("terminated")
        #expect(inbox.output.contains("done [0, 1, 4]"), "output: \(inbox.output)")
        _ = try? await client.request("disconnect", arguments: ["terminateDebuggee": true])
    }

    /// The debuggee is launched by us via runInTerminal, so its stdin is ours and input() works.
    @Test(.enabled(if: canRun), .timeLimit(.minutes(1)))
    func runInTerminalGivesDebuggeeStdin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-dbg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let program = dir.appendingPathComponent("ask.py")
        try "name = input('Name? ')\nprint(f'Hello {name}!')\n".write(to: program, atomically: true, encoding: .utf8)

        let python = try #require(PythonEnvironment.interpreter(for: nil))
        let inbox = EventInbox()
        let output = REPLSessionTests.Collector()
        let debuggee = PipedProcess()
        debuggee.onOutput = { output.append($0) }
        let client = DAPClient()
        client.onEvent = { inbox.add($0, $1) }
        client.onReverseRequest = { command, arguments in
            guard command == "runInTerminal" else { return nil }
            let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            try debuggee.start(arguments: args,
                               environment: PipedProcess.environment(base: ToolLocator.environment(), overrides: arguments["env"]),
                               currentDirectory: arguments["cwd"]?.stringValue.map { URL(fileURLWithPath: $0) })
            return ["processId": .int(Int(debuggee.processIdentifier))]
        }
        try client.start(executable: python, arguments: ["-m", "debugpy.adapter"],
                         environment: DebugpyLocator.adapterEnvironment(base: ToolLocator.environment(), useSupportDirectory: true),
                         currentDirectory: dir)
        defer {
            client.terminate()
            debuggee.terminate()
        }

        _ = try await client.request("initialize", arguments: [
            "clientID": "pyide", "adapterID": "debugpy", "linesStartAt1": true, "columnsStartAt1": true,
            "pathFormat": "path", "supportsRunInTerminalRequest": true,
        ])
        let launch = Task {
            try await client.request("launch", arguments: [
                "program": .string(program.path), "cwd": .string(dir.path), "python": [.string(python.path)],
                "console": "integratedTerminal", "justMyCode": true,
            ])
        }
        _ = try await inbox.next("initialized")
        _ = try await client.request("configurationDone")
        _ = try await launch.value

        for _ in 0..<200 where !output.value.contains("Name?") { try await Task.sleep(for: .milliseconds(25)) }
        debuggee.send("Ada\n")
        _ = try await inbox.next("terminated")
        for _ in 0..<40 where !output.value.contains("Hello Ada!") { try await Task.sleep(for: .milliseconds(25)) }
        #expect(output.value.contains("Name? ") && output.value.contains("Hello Ada!"), "output: \(output.value)")
    }
}
