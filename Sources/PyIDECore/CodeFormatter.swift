import Foundation

/// An external Python formatter (ruff or black) that reads source on stdin and writes it to stdout.
public struct CodeFormatter: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case ruff, black
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What to do to the source. Fixes need ruff; black can only format.
    public enum Operation: Sendable {
        case format, fixAll, organizeImports

        public var title: String {
            switch self {
            case .format: "Format"
            case .fixAll: "Fix All"
            case .organizeImports: "Organize Imports"
            }
        }
    }

    public let kind: Kind
    public let executable: URL

    public init(kind: Kind, executable: URL) {
        self.kind = kind
        self.executable = executable
    }

    public var name: String { kind.rawValue }

    /// ruff first (fast, and picks up `[tool.ruff]` config), then black. Tools in the
    /// interpreter's environment win over global ones.
    public static func locate(
        interpreter: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodeFormatter? {
        let extra = PythonEnvironment.toolDirectories(for: interpreter)
        if let ruff = ToolLocator.find("ruff", in: extra, environment: environment) {
            return CodeFormatter(kind: .ruff, executable: ruff)
        }
        if let black = ToolLocator.find("black", in: extra, environment: environment) {
            return CodeFormatter(kind: .black, executable: black)
        }
        return nil
    }

    /// `--stdin-filename` lets the tool find the project's config and apply per-file settings.
    public func arguments(for file: URL, operation: Operation = .format) -> [String]? {
        switch (kind, operation) {
        case (.ruff, .format): ["format", "--stdin-filename", file.path, "-"]
        // `check --fix` on stdin prints the fixed source; --exit-zero because unfixable issues remain.
        case (.ruff, .fixAll): ["check", "--fix", "--exit-zero", "--quiet", "--stdin-filename", file.path, "-"]
        case (.ruff, .organizeImports):
            ["check", "--select", "I", "--fix", "--exit-zero", "--quiet", "--stdin-filename", file.path, "-"]
        case (.black, .format): ["--quiet", "--stdin-filename", file.path, "-"]
        case (.black, _): nil
        }
    }

    /// Formats `source`. Throws `Failure` with the tool's message (e.g. a syntax error).
    public func format(
        _ source: String,
        file: URL,
        operation: Operation = .format,
        environment: [String: String],
        currentDirectory: URL?,
        timeout: Duration = .seconds(10)
    ) async throws -> String {
        let executable = executable
        guard let arguments = arguments(for: file, operation: operation) else {
            throw Failure(message: "\(operation.title) needs ruff (uv tool install ruff)")
        }
        let name = name
        return try await Task.detached {
            try Self.run(executable: executable, arguments: arguments, input: Data(source.utf8),
                         environment: environment, currentDirectory: currentDirectory, timeout: timeout, name: name)
        }.value
    }

    private static func run(
        executable: URL, arguments: [String], input: Data, environment: [String: String],
        currentDirectory: URL?, timeout: Duration, name: String
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Write and read concurrently so neither side blocks on a full pipe.
        let group = DispatchGroup()
        nonisolated(unsafe) var errorData = Data()
        group.enter()
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw Failure(message: "\(name) timed out")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? "exit status \(process.terminationStatus)"
            throw Failure(message: "\(name): \(message)")
        }
        return String(decoding: output, as: UTF8.self)
    }
}
