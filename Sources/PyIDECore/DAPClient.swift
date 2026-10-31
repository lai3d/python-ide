import Foundation

/// A minimal Debug Adapter Protocol client over stdio (same `Content-Length` framing as LSP),
/// or over TCP to an adapter that is already listening (`python -m debugpy --listen`).
public final class DAPClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ event: String, _ body: JSONValue) -> Void
    public typealias ExitHandler = @Sendable (_ status: Int32) -> Void
    /// Answers a reverse request (e.g. `runInTerminal`): return the response body, or nil to decline.
    public typealias ReverseRequestHandler = @Sendable (_ command: String, _ arguments: JSONValue) throws -> JSONValue?

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
    /// The TCP connection when connected to a listening adapter instead of running one.
    private var socket: FileHandle?
    private var framer = LSPFramer()
    private var nextSeq = 1
    private var pending: [Int: (command: String, continuation: CheckedContinuation<JSONValue, any Error>)] = [:]
    private var _onEvent: EventHandler?
    private var _onExit: ExitHandler?
    private var _onReverseRequest: ReverseRequestHandler?
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

    public var onReverseRequest: ReverseRequestHandler? {
        get { lock.withLock { _onReverseRequest } }
        set { lock.withLock { _onReverseRequest = newValue } }
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

    /// Connects to an adapter listening on `host:port`. Blocks while connecting, so call it off
    /// the main thread.
    public func connect(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        guard status == 0, let first = info else {
            throw ClientError.failed(command: "connect", message: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(first) }
        var lastError = ECONNREFUSED
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            candidate = address.pointee.ai_next
            let fd = Darwin.socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
                lastError = errno
                close(fd)
                continue
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.handleExit(0)
                    return
                }
                self?.receive(data)
            }
            lock.withLock {
                socket = handle
                stdin = handle
            }
            return
        }
        throw ClientError.failed(command: "connect to \(host):\(port)", message: String(cString: strerror(lastError)))
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
        let (p, socket) = lock.withLock { (process, self.socket) }
        if let p, p.isRunning { p.terminate() }
        if let socket {
            socket.readabilityHandler = nil
            shutdown(socket.fileDescriptor, SHUT_RDWR)
            handleExit(0)
        }
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
            // Reverse requests (e.g. runInTerminal).
            guard let seq = message["seq"]?.intValue, let command = message["command"]?.stringValue else { return }
            var response: [String: JSONValue] = ["seq": 0, "type": "response", "request_seq": .int(seq),
                                                 "command": .string(command)]
            do {
                if let body = try onReverseRequest?(command, message["arguments"] ?? .null) {
                    response["success"] = true
                    response["body"] = body
                } else {
                    response["success"] = false
                    response["message"] = "not supported"
                }
            } catch {
                response["success"] = false
                response["message"] = .string(error.localizedDescription)
            }
            try? send(.object(response))
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
            socket = nil
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

public struct ThreadInfo: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    /// Parses a `threads` response body.
    public static func parseAll(_ body: JSONValue) -> [ThreadInfo] {
        (body["threads"]?.arrayValue ?? []).compactMap { thread in
            guard let id = thread["id"]?.intValue else { return nil }
            return ThreadInfo(id: id, name: thread["name"]?.stringValue ?? "Thread \(id)")
        }
    }
}

/// What a debug session runs or attaches to.
public enum DebugTarget: Sendable, Hashable {
    /// Start `program` under the debugger.
    case launch(program: URL, cwd: URL)
    /// Connect to a program already listening (`python -m debugpy --listen host:port …`).
    case connect(host: String, port: Int)
    /// Inject debugpy into a running Python process (needs lldb and permission to attach).
    case process(id: Int32)

    public var isAttach: Bool {
        if case .launch = self { false } else { true }
    }

    public var displayName: String {
        switch self {
        case .launch(let program, _): program.lastPathComponent
        case .connect(let host, let port): "\(host):\(port)"
        case .process(let id): "process \(id)"
        }
    }

    /// Parses an attach address: `5678`, `:5678`, `host:5678` connect; `pid 123` or `pid:123` attach to a process.
    public static func parseAttach(_ text: String) -> DebugTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("pid") {
            let digits = lower.dropFirst(3).drop { $0 == " " || $0 == ":" || $0 == "=" }
            return Int32(digits).flatMap { $0 > 0 ? .process(id: $0) : nil }
        }
        let host: Substring
        let portText: Substring
        if let colon = trimmed.lastIndex(of: ":") {
            host = trimmed[..<colon]
            portText = trimmed[trimmed.index(after: colon)...]
        } else {
            host = ""
            portText = Substring(trimmed)
        }
        guard let port = Int(portText), (1...65535).contains(port), !host.contains(" ") else { return nil }
        return .connect(host: host.isEmpty ? "127.0.0.1" : String(host), port: port)
    }

    /// DAP `launch` / `attach` arguments for debugpy (launch also needs the interpreter path).
    public func requestArguments(python: URL) -> (command: String, arguments: JSONValue) {
        switch self {
        case .launch(let program, let cwd):
            return ("launch", [
                "program": .string(program.path), "cwd": .string(cwd.path), "python": [.string(python.path)],
                // integratedTerminal: debugpy asks us (runInTerminal) to start the program, giving us its stdin.
                "console": "integratedTerminal", "justMyCode": true,
                "env": ["PYTHONUNBUFFERED": "1"],
            ])
        case .connect(let host, let port):
            return ("attach", ["connect": ["host": .string(host), "port": .int(port)], "justMyCode": true])
        case .process(let id):
            return ("attach", ["processId": .int(Int(id)), "justMyCode": true])
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
