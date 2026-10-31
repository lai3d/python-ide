import Foundation

/// A minimal Debug Adapter Protocol client over stdio (same `Content-Length` framing as LSP).
public final class DAPClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ event: String, _ body: JSONValue) -> Void
    public typealias ExitHandler = @Sendable (_ status: Int32) -> Void

    public enum ClientError: Error, LocalizedError {
        case notRunning
        case failed(command: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: "debug adapter is not running"
            case .failed(let command, let message): "\(command) failed: \(message)"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var framer = LSPFramer()
    private var nextSeq = 1
    private var pending: [Int: (command: String, continuation: CheckedContinuation<JSONValue, any Error>)] = [:]
    private var _onEvent: EventHandler?
    private var _onExit: ExitHandler?
    private var stderrText = ""

    public init() {}

    /// Called (on a background thread) for every adapter event.
    public var onEvent: EventHandler? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    public var onExit: ExitHandler? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    /// Adapter stderr so far (useful when it fails to start).
    public var stderrOutput: String { lock.withLock { stderrText } }

    public func start(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock { if self.stderrText.count < 20_000 { self.stderrText += text } }
        }
        p.terminationHandler = { [weak self] proc in self?.handleExit(proc.terminationStatus) }
        try p.run()
        lock.withLock {
            process = p
            stdin = inPipe.fileHandleForWriting
        }
    }

    /// Sends a request and waits for its response body. Throws if `success` is false.
    public func request(_ command: String, arguments: JSONValue = .null) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let seq: Int = lock.withLock {
                let seq = nextSeq
                nextSeq += 1
                pending[seq] = (command, continuation)
                return seq
            }
            var message: [String: JSONValue] = ["seq": .int(seq), "type": "request", "command": .string(command)]
            if !arguments.isNull { message["arguments"] = arguments }
            do {
                try send(.object(message))
            } catch {
                if let entry = lock.withLock({ pending.removeValue(forKey: seq) }) {
                    entry.continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sends a request without waiting for the response.
    public func send(_ command: String, arguments: JSONValue = .null) {
        Task { _ = try? await request(command, arguments: arguments) }
    }

    public func terminate() {
        let p = lock.withLock { process }
        if let p, p.isRunning { p.terminate() }
    }

    // MARK: - Private

    private func send(_ message: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = LSPFramer.frame(try encoder.encode(message))
        try lock.withLock {
            guard let stdin else { throw ClientError.notRunning }
            try stdin.write(contentsOf: data)
        }
    }

    private func receive(_ data: Data) {
        let bodies = lock.withLock { framer.append(data) }
        let decoder = JSONDecoder()
        for body in bodies {
            guard let message = try? decoder.decode(JSONValue.self, from: body) else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: JSONValue) {
        switch message["type"]?.stringValue {
        case "response":
            guard let seq = message["request_seq"]?.intValue,
                  let entry = lock.withLock({ pending.removeValue(forKey: seq) }) else { return }
            if message["success"]?.boolValue == true {
                entry.continuation.resume(returning: message["body"] ?? .null)
            } else {
                let detail = message["body"]?["error"]?["format"]?.stringValue
                    ?? message["message"]?.stringValue ?? "unknown error"
                entry.continuation.resume(throwing: ClientError.failed(command: entry.command, message: detail))
            }
        case "event":
            guard let event = message["event"]?.stringValue else { return }
            onEvent?(event, message["body"] ?? .null)
        case "request":
            // Reverse requests (e.g. runInTerminal): we advertise no support, so decline.
            guard let seq = message["seq"]?.intValue, let command = message["command"]?.stringValue else { return }
            try? send(["seq": 0, "type": "response", "request_seq": .int(seq), "command": .string(command),
                       "success": false, "message": "not supported"])
        default:
            break
        }
    }

    private func handleExit(_ status: Int32) {
        let (waiters, handler) = lock.withLock {
            let waiters = pending.values.map(\.continuation)
            pending.removeAll()
            stdin = nil
            process = nil
            return (waiters, _onExit)
        }
        for waiter in waiters { waiter.resume(throwing: ClientError.notRunning) }
        handler?(status)
    }
}

// MARK: - Models

public struct StackFrameInfo: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let path: String?
    /// 1-based, as DAP sends with `linesStartAt1`.
    public let line: Int

    public init(id: Int, name: String, path: String?, line: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.line = line
    }

    public static func parseAll(_ body: JSONValue) -> [StackFrameInfo] {
        (body["stackFrames"]?.arrayValue ?? []).compactMap { frame in
            guard let id = frame["id"]?.intValue, let name = frame["name"]?.stringValue else { return nil }
            return StackFrameInfo(id: id, name: name, path: frame["source"]?["path"]?.stringValue,
                                  line: frame["line"]?.intValue ?? 0)
        }
    }
}

public struct VariableInfo: Sendable, Hashable, Identifiable {
    public let name: String
    public let value: String
    public let type: String?
    /// > 0 when the value has children (fetch them with `variables`).
    public let reference: Int
    public var id: String { "\(reference)-\(name)" }

    public init(name: String, value: String, type: String?, reference: Int) {
        self.name = name
        self.value = value
        self.type = type
        self.reference = reference
    }

    /// Parses a `scopes` body (as pseudo-variables) or a `variables` body.
    public static func parseAll(_ body: JSONValue) -> [VariableInfo] {
        let items = body["variables"]?.arrayValue ?? body["scopes"]?.arrayValue ?? []
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return VariableInfo(name: name, value: item["value"]?.stringValue ?? "",
                                type: item["type"]?.stringValue,
                                reference: item["variablesReference"]?.intValue ?? 0)
        }
    }
}

/// Finds or installs debugpy, and builds the adapter command line.
public enum DebugpyLocator {
    /// PyIDE's private install location (`pip install --target`), used when the project's
    /// interpreter doesn't have debugpy itself.
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PyIDE/debugpy")
    }

    public static var isInstalledInSupportDirectory: Bool {
        FileManager.default.fileExists(atPath: supportDirectory.appendingPathComponent("debugpy/__init__.py").path)
    }

    /// Environment for running the adapter with `interpreter -m debugpy.adapter`.
    public static func adapterEnvironment(base: [String: String], useSupportDirectory: Bool) -> [String: String] {
        var env = base
        if useSupportDirectory {
            let existing = env["PYTHONPATH"].map { ":" + $0 } ?? ""
            env["PYTHONPATH"] = supportDirectory.path + existing
        }
        return env
    }

    /// The command that installs debugpy into the support directory: uv if available, else pip.
    public static func installCommand(interpreter: URL) -> (executable: URL, arguments: [String]) {
        if let uv = ToolLocator.find("uv") {
            return (uv, ["pip", "install", "--target", supportDirectory.path, "--python", interpreter.path, "debugpy"])
        }
        return (interpreter, ["-m", "pip", "install", "--target", supportDirectory.path, "--upgrade", "debugpy"])
    }
}
