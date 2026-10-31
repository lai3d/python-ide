import Foundation

/// A child process with stdin/stdout/stderr on pipes, streaming merged output.
/// Used for the debuggee when the debug adapter asks us to launch it (`runInTerminal`),
/// so the program's stdin (for `input()`) belongs to the IDE.
public final class PipedProcess: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (String) -> Void
    public typealias ExitHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private let process = Process()
    private var stdin: FileHandle?
    private var _onOutput: OutputHandler?
    private var _onExit: ExitHandler?

    public init() {}

    public var onOutput: OutputHandler? {
        get { lock.withLock { _onOutput } }
        set { lock.withLock { _onOutput = newValue } }
    }

    public var onExit: ExitHandler? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Starts `arguments[0]` (an absolute path or a name resolved on the environment's PATH).
    public func start(arguments: [String], environment: [String: String], currentDirectory: URL?) throws {
        guard let first = arguments.first else { throw CocoaError(.executableNotLoadable) }
        if first.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: first)
            process.arguments = Array(arguments.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
        }
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.onOutput?(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let handler = self.lock.withLock {
                self.stdin = nil
                return self._onExit
            }
            handler?(proc.terminationStatus)
        }
        try process.run()
        lock.withLock { stdin = input.fileHandleForWriting }
    }

    public func send(_ text: String) {
        lock.withLock { try? stdin?.write(contentsOf: Data(text.utf8)) }
    }

    /// Closes stdin (EOF, like Ctrl-D).
    public func closeInput() {
        lock.withLock {
            try? stdin?.close()
            stdin = nil
        }
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Applies a DAP `runInTerminal` env map to a base environment (null values unset a variable).
    public static func environment(base: [String: String], overrides: JSONValue?) -> [String: String] {
        var env = base
        for (key, value) in overrides?.objectValue ?? [:] {
            if let string = value.stringValue { env[key] = string } else { env.removeValue(forKey: key) }
        }
        return env
    }
}
