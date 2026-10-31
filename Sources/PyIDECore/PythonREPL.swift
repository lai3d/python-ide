import Foundation

/// An interactive Python session (`python -i`) over pipes. Prompts (`>>> `, `... `) arrive on
/// stderr, which is merged with stdout so the transcript reads like a terminal.
public final class PythonREPL: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (String) -> Void
    public typealias ExitHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private var process: Process?
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

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    public func start(interpreter: URL, environment: [String: String], currentDirectory: URL?) throws {
        let p = Process()
        p.executableURL = interpreter
        // -i: interactive even without a tty; -u: unbuffered; -q: no banner (we print our own).
        p.arguments = ["-i", "-u", "-q"]
        var env = environment
        env["PYTHON_BASIC_REPL"] = "1"  // the 3.13+ REPL needs a real terminal
        env["PYTHONIOENCODING"] = "utf-8"
        p.environment = env
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }

        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.onOutput?(String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let handler = self.lock.withLock {
                self.process = nil
                self.stdin = nil
                return self._onExit
            }
            handler?(proc.terminationStatus)
        }
        try p.run()
        lock.withLock {
            process = p
            stdin = input.fileHandleForWriting
        }
    }

    /// Sends source text. Each line is fed to the REPL as if typed.
    public func send(_ text: String) {
        let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        lock.withLock { try? stdin?.write(contentsOf: data) }
    }

    /// Ctrl-C: raises KeyboardInterrupt in the running code.
    public func interrupt() {
        lock.withLock { process }?.interrupt()
    }

    public func stop() {
        let p = lock.withLock {
            try? stdin?.close()
            stdin = nil
            return process
        }
        if let p, p.isRunning { p.terminate() }
    }

    /// Prepares an editor selection for the REPL: drops blank lines inside blocks (they would
    /// end the block early), removes common indentation, and adds the blank line that closes
    /// a trailing indented block.
    public static func prepareForSending(_ code: String) -> String {
        var lines = code.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        guard !lines.isEmpty else { return "" }

        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        lines = lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }

        // Keep top-level blank lines (separating statements); drop those inside an indented block.
        var result: [String] = []
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                let next = lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let next, next.first == " " || next.first == "\t" { continue }
            }
            result.append(line)
        }
        var text = result.joined(separator: "\n") + "\n"
        if let last = result.last, last.first == " " || last.first == "\t" { text += "\n" }
        return text
    }
}
