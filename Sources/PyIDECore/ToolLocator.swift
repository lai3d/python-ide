import Foundation

/// Finds Python tooling. GUI apps launched from Finder get a minimal PATH, so we
/// also look in the usual Homebrew, pipx/uv and npm install locations.
public enum ToolLocator {
    public static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let venv = environment["VIRTUAL_ENV"] { dirs.insert("\(venv)/bin", at: 0) }
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                 "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Looks in `extraDirectories` first (e.g. a project's `.venv/bin`), then the search path.
    public static func find(
        _ name: String,
        in extraDirectories: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        for dir in extraDirectories + searchDirectories(environment: environment) {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// The current environment with PATH widened to every search directory, so child
    /// processes (pyright needs node) can find each other. With a virtualenv interpreter,
    /// its `bin` goes first and `VIRTUAL_ENV` is set, like `source .venv/bin/activate`.
    public static func environment(
        interpreter: URL? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        var dirs = searchDirectories(environment: base)
        if let interpreter, let venv = PythonEnvironment.virtualEnvRoot(of: interpreter) {
            env["VIRTUAL_ENV"] = venv.path
            dirs.insert(venv.appendingPathComponent("bin").path, at: 0)
        }
        var seen = Set<String>()
        env["PATH"] = dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"  // stream print() output to the Output panel immediately
        env.removeValue(forKey: "PYTHONHOME")
        return env
    }
}

/// Picks the Python interpreter for a project.
public enum PythonEnvironment {
    /// Virtualenv folder names checked in the project root, in order.
    public static let venvNames = [".venv", "venv", "env", ".env"]

    /// The project's virtualenv python if there is one, else `$VIRTUAL_ENV`, else `python3` on the path.
    public static func interpreter(
        for root: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let root {
            for name in venvNames {
                let candidate = root.appendingPathComponent(name).appendingPathComponent("bin/python")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        if let venv = environment["VIRTUAL_ENV"] {
            let candidate = URL(fileURLWithPath: venv).appendingPathComponent("bin/python")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return ToolLocator.find("python3", environment: environment) ?? ToolLocator.find("python", environment: environment)
    }

    /// The virtualenv containing `interpreter` (`<venv>/bin/python` with a `pyvenv.cfg`), if any.
    /// Uses the unresolved path: venv pythons are symlinks to the base interpreter.
    public static func virtualEnvRoot(of interpreter: URL) -> URL? {
        let venv = interpreter.deletingLastPathComponent().deletingLastPathComponent()
        let cfg = venv.appendingPathComponent("pyvenv.cfg")
        return FileManager.default.fileExists(atPath: cfg.path) ? venv : nil
    }

    /// Directories to search before PATH for tools installed into the interpreter's environment.
    public static func toolDirectories(for interpreter: URL?) -> [String] {
        guard let interpreter else { return [] }
        return [interpreter.deletingLastPathComponent().path]
    }
}

/// A Python language server we know how to launch.
public struct LanguageServerSpec: Sendable, Hashable {
    public let name: String
    public let executable: String
    public let arguments: [String]

    public init(name: String, executable: String, arguments: [String]) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
    }

    /// Preference order: pyright-family first (best completions and type checking).
    public static let candidates: [LanguageServerSpec] = [
        LanguageServerSpec(name: "basedpyright", executable: "basedpyright-langserver", arguments: ["--stdio"]),
        LanguageServerSpec(name: "pyright", executable: "pyright-langserver", arguments: ["--stdio"]),
        LanguageServerSpec(name: "pylsp", executable: "pylsp", arguments: []),
        LanguageServerSpec(name: "jedi", executable: "jedi-language-server", arguments: []),
    ]

    public static func locate(
        interpreter: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (spec: LanguageServerSpec, url: URL)? {
        let extra = PythonEnvironment.toolDirectories(for: interpreter)
        for spec in candidates {
            if let url = ToolLocator.find(spec.executable, in: extra, environment: environment) { return (spec, url) }
        }
        return nil
    }

    public static let installHint = "npm install -g pyright   (or: uv tool install basedpyright)"

    /// Answers a `workspace/configuration` request: tells pyright which interpreter to use.
    public static func configuration(items: [JSONValue], pythonPath: String?) -> JSONValue {
        .array(items.map { item in
            switch item["section"]?.stringValue {
            case "python":
                var python: [String: JSONValue] = [:]
                if let pythonPath { python["pythonPath"] = .string(pythonPath) }
                python["analysis"] = analysisSettings
                return .object(python)
            case "python.analysis", "basedpyright.analysis":
                return analysisSettings
            case "basedpyright":
                return ["analysis": analysisSettings]
            default:
                return .null
            }
        })
    }

    private static let analysisSettings: JSONValue = [
        "autoSearchPaths": true,
        "useLibraryCodeForTypes": true,
        "diagnosticMode": "openFilesOnly",
        "typeCheckingMode": "standard",
    ]
}
