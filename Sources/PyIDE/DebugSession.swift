import Foundation
import Observation
import PyIDECore

/// One debugpy session: drives the DAP client and holds the state the Debug panel shows.
@MainActor
@Observable
final class DebugSession {
    enum State: Equatable {
        case starting, running, stopped, ended
    }

    private(set) var state: State = .starting
    private(set) var stopDescription = ""
    private(set) var frames: [StackFrameInfo] = []
    private(set) var selectedFrameID: Int?
    private(set) var scopes: [VariableInfo] = []
    /// Bumped on every stop so variable trees (whose references are only valid per stop) rebuild.
    private(set) var stopCount = 0
    private(set) var console = ""
    /// Watch expression → its value in the selected frame (or the error message).
    private(set) var watchValues: [String: String] = [:]
    private(set) var watchExpressions: [String] = []

    @ObservationIgnored private let client = DAPClient()
    @ObservationIgnored private var threadID: Int?
    @ObservationIgnored private var breakpoints: [String: [SourceBreakpoint]]
    /// The program itself, started by us at the adapter's request so its stdin is ours.
    @ObservationIgnored private var debuggee: PipedProcess?
    @ObservationIgnored private var launchTask: Task<Void, Never>?

    /// Called when execution stops at a location (path, 1-based line), or with nil when it resumes.
    @ObservationIgnored var onLocation: ((String, Int)?) -> Void = { _ in }
    @ObservationIgnored var onEnd: () -> Void = {}

    let programName: String

    init(breakpoints: [String: [SourceBreakpoint]], programName: String) {
        self.breakpoints = breakpoints
        self.programName = programName
    }

    var isStopped: Bool { state == .stopped }
    var isActive: Bool { state != .ended }

    // MARK: Lifecycle

    func start(python: URL, program: URL, cwd: URL, environment: [String: String], useSupportDirectory: Bool) {
        client.onEvent = { [weak self] event, body in
            Task { @MainActor in self?.handle(event: event, body: body) }
        }
        let baseEnvironment = environment
        client.onReverseRequest = { [weak self] command, arguments in
            guard command == "runInTerminal" else { return nil }
            let process = PipedProcess()
            process.onOutput = { text in Task { @MainActor in self?.log(text) } }
            let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            try process.start(arguments: args,
                              environment: PipedProcess.environment(base: baseEnvironment, overrides: arguments["env"]),
                              currentDirectory: arguments["cwd"]?.stringValue.map { URL(fileURLWithPath: $0) })
            Task { @MainActor in self?.debuggee = process }
            return ["processId": .int(Int(process.processIdentifier))]
        }
        client.onExit = { [weak self] status in
            Task { @MainActor in
                guard let self, self.state != .ended else { return }
                if status != 0 {
                    let stderr = self.client.stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.log("\n[debug adapter exited with status \(status)]\(stderr.isEmpty ? "" : "\n" + stderr)\n")
                }
                self.end()
            }
        }
        do {
            try client.start(executable: python, arguments: ["-m", "debugpy.adapter"],
                             environment: DebugpyLocator.adapterEnvironment(base: environment, useSupportDirectory: useSupportDirectory),
                             currentDirectory: cwd)
        } catch {
            log("Failed to start debugpy: \(error.localizedDescription)\n")
            end()
            return
        }
        launchTask = Task {
            do {
                _ = try await client.request("initialize", arguments: [
                    "clientID": "pyide", "clientName": "PyIDE", "adapterID": "debugpy",
                    "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
                    "supportsRunInTerminalRequest": true, "supportsVariableType": true,
                ])
                // debugpy replies to `launch` after configurationDone (sent on the `initialized` event).
                _ = try await client.request("launch", arguments: [
                    "program": .string(program.path), "cwd": .string(cwd.path), "python": [.string(python.path)],
                    // integratedTerminal: debugpy asks us (runInTerminal) to start the program, giving us its stdin.
                    "console": "integratedTerminal", "justMyCode": true,
                    "env": ["PYTHONUNBUFFERED": "1"],
                ])
                if state == .starting { state = .running }
            } catch {
                log("Launch failed: \(error.localizedDescription)\n")
                stop()
            }
        }
    }

    func stop() {
        guard state != .ended else { return }
        Task {
            _ = try? await client.request("disconnect", arguments: ["terminateDebuggee": true])
            try? await Task.sleep(for: .milliseconds(300))
            client.terminate()
        }
        end()
    }

    private func end() {
        guard state != .ended else { return }
        state = .ended
        debuggee?.terminate()
        debuggee = nil
        frames = []
        scopes = []
        onLocation(nil)
        log("\n[debug session ended]\n")
        onEnd()
    }

    // MARK: Breakpoints

    func setBreakpoints(path: String, _ list: [SourceBreakpoint]) {
        breakpoints[path] = list
        guard state != .starting, state != .ended else { return }
        client.send("setBreakpoints", arguments: Self.breakpointArguments(path: path, list))
    }

    private static func breakpointArguments(path: String, _ list: [SourceBreakpoint]) -> JSONValue {
        ["source": ["path": .string(path)], "breakpoints": .array(list.sorted { $0.line < $1.line }.map(\.json))]
    }

    private func sendConfiguration() async {
        for (path, list) in breakpoints {
            _ = try? await client.request("setBreakpoints", arguments: Self.breakpointArguments(path: path, list))
        }
        _ = try? await client.request("setExceptionBreakpoints", arguments: ["filters": ["uncaught"]])
        _ = try? await client.request("configurationDone")
    }

    // MARK: Execution control

    func resume() { control("continue") }
    func stepOver() { control("next") }
    func stepIn() { control("stepIn") }
    func stepOut() { control("stepOut") }

    func pause() {
        guard state == .running else { return }
        client.send("pause", arguments: ["threadId": .int(threadID ?? 1)])
    }

    private func control(_ command: String) {
        guard state == .stopped, let threadID else { return }
        state = .running
        watchValues = [:]
        frames = []
        scopes = []
        onLocation(nil)
        client.send(command, arguments: ["threadId": .int(threadID)])
    }

    // MARK: Program input

    /// Console input: evaluates while paused, otherwise goes to the program's stdin.
    func submitConsoleInput(_ line: String) {
        if state == .stopped {
            evaluate(line)
        } else if let debuggee, debuggee.isRunning {
            log(line + "\n")
            debuggee.send(line + "\n")
        }
    }

    func sendEOF() { debuggee?.closeInput() }

    // MARK: Inspection

    func setWatches(_ expressions: [String]) {
        watchExpressions = expressions
        refreshWatches()
    }

    /// Evaluates every watch expression in the selected frame.
    func refreshWatches() {
        guard state == .stopped, let frameID = selectedFrameID else {
            watchValues = [:]
            return
        }
        for expression in watchExpressions {
            Task {
                let value: String
                do {
                    let body = try await client.request("evaluate", arguments: [
                        "expression": .string(expression), "frameId": .int(frameID), "context": "watch",
                    ])
                    value = body["result"]?.stringValue ?? ""
                } catch {
                    value = "⚠︎ " + (error.localizedDescription.components(separatedBy: "failed: ").last ?? "error")
                }
                guard selectedFrameID == frameID else { return }
                watchValues[expression] = value
            }
        }
    }

    func select(frame: StackFrameInfo) {
        selectedFrameID = frame.id
        if let path = frame.path { onLocation((path, frame.line)) }
        refreshWatches()
        Task {
            let body = try? await client.request("scopes", arguments: ["frameId": .int(frame.id)])
            guard selectedFrameID == frame.id else { return }
            scopes = body.map(VariableInfo.parseAll) ?? []
            stopCount += 1
        }
    }

    func children(of reference: Int) async -> [VariableInfo] {
        guard reference > 0, state == .stopped,
              let body = try? await client.request("variables", arguments: ["variablesReference": .int(reference)])
        else { return [] }
        return VariableInfo.parseAll(body)
    }

    /// Assigns `value` (a Python expression) to a variable, then refreshes variables and watches.
    func setVariable(_ name: String, in container: Int, to value: String) async -> String? {
        guard state == .stopped else { return "Pause first" }
        do {
            _ = try await client.request("setVariable", arguments: [
                "variablesReference": .int(container), "name": .string(name), "value": .string(value),
            ])
        } catch {
            return error.localizedDescription.components(separatedBy: "failed: ").last
        }
        if let frame = frames.first(where: { $0.id == selectedFrameID }) { select(frame: frame) }
        return nil
    }

    /// Evaluates an expression in the selected frame (or globally while running) and logs the result.
    func evaluate(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, state != .ended else { return }
        log(">>> \(trimmed)\n")
        var arguments: [String: JSONValue] = ["expression": .string(trimmed), "context": "repl"]
        if let selectedFrameID { arguments["frameId"] = .int(selectedFrameID) }
        Task {
            do {
                let body = try await client.request("evaluate", arguments: .object(arguments))
                log((body["result"]?.stringValue ?? "") + "\n")
            } catch {
                log("\(error.localizedDescription)\n")
            }
        }
    }

    // MARK: Events

    private func handle(event: String, body: JSONValue) {
        guard state != .ended else { return }
        switch event {
        case "initialized":
            Task { await sendConfiguration() }
        case "stopped":
            threadID = body["threadId"]?.intValue ?? threadID
            state = .stopped
            let reason = body["reason"]?.stringValue ?? "pause"
            stopDescription = body["description"]?.stringValue ?? "Paused on \(reason)"
            Task { await loadStack(reason: reason) }
        case "continued":
            if state == .stopped {
                state = .running
                frames = []
                scopes = []
                onLocation(nil)
            }
        case "output":
            let category = body["category"]?.stringValue ?? "console"
            guard category != "telemetry", let text = body["output"]?.stringValue else { return }
            log(text)
        case "terminated", "exited":
            if event == "exited", let code = body["exitCode"]?.intValue { log("\n[process exited with status \(code)]\n") }
            if event == "terminated" { stop() }
        default:
            break
        }
    }

    private func loadStack(reason: String) async {
        guard let threadID,
              let body = try? await client.request("stackTrace", arguments: ["threadId": .int(threadID), "levels": 50])
        else { return }
        frames = StackFrameInfo.parseAll(body)
        if reason == "exception",
           let info = try? await client.request("exceptionInfo", arguments: ["threadId": .int(threadID)]) {
            let id = info["exceptionId"]?.stringValue ?? "Exception"
            let description = info["description"]?.stringValue ?? ""
            stopDescription = "\(id): \(description)"
            log("\n\(stopDescription)\n")
        }
        if let top = frames.first(where: { $0.path != nil }) ?? frames.first { select(frame: top) }
    }

    private func log(_ text: String) {
        console += text
        if console.utf16.count > 400_000 { console = String(console.suffix(300_000)) }
    }
}
