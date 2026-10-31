import Foundation

/// Runs notebook cells in a persistent Python process (a small helper script; no Jupyter install
/// needed). Each cell's outputs come back as nbformat output objects, so they can be stored in
/// the .ipynb as-is.
public final class NotebookKernel: @unchecked Sendable {
    public enum Event: Sendable {
        /// An nbformat output object (stream / execute_result / display_data / error) for a cell run.
        case output(runID: Int, JSONValue)
        /// The run finished; `executionCount` is the cell's new `[n]`.
        case done(runID: Int, executionCount: Int)
        /// The program called `input(prompt)`; answer with `sendInput`.
        case inputRequest(prompt: String)
        /// Raw text written outside Python's sys.stdout/stderr (C extensions, subprocesses).
        case rawOutput(String)
        case exited(Int32)
    }

    public typealias EventHandler = @Sendable (Event) -> Void

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextRunID = 1
    private var _onEvent: EventHandler?

    public init() {}

    public var onEvent: EventHandler? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    public func start(interpreter: URL, environment: [String: String], currentDirectory: URL?) throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("pyide_kernel_\(getpid()).py")
        try Self.helperSource.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = interpreter
        p.arguments = ["-u", script.path]
        var env = environment
        env["MPLBACKEND"] = "Agg"  // render figures off-screen; the helper turns them into PNG outputs
        env["PYTHONIOENCODING"] = "utf-8"
        p.environment = env
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.onEvent?(.rawOutput(String(decoding: data, as: UTF8.self)))
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let handler = self.lock.withLock {
                self.process = nil
                self.stdin = nil
                return self._onEvent
            }
            handler?(.exited(proc.terminationStatus))
        }
        try p.run()
        lock.withLock {
            process = p
            stdin = input.fileHandleForWriting
        }
    }

    /// Queues `code` for execution and returns its run ID (events carry it).
    @discardableResult
    public func execute(_ code: String) -> Int {
        let id = lock.withLock {
            defer { nextRunID += 1 }
            return nextRunID
        }
        send(["type": "execute", "id": .int(id), "code": .string(code)])
        return id
    }

    public func sendInput(_ text: String) {
        send(["type": "input_reply", "value": .string(text)])
    }

    /// Raises KeyboardInterrupt in the running cell.
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

    private func send(_ message: JSONValue) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        lock.withLock { try? stdin?.write(contentsOf: data) }
    }

    private func receive(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
            }
            return lines
        }
        for line in lines {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
            switch message["type"]?.stringValue {
            case "output":
                if let id = message["id"]?.intValue, let output = message["output"] { onEvent?(.output(runID: id, output)) }
            case "done":
                if let id = message["id"]?.intValue {
                    onEvent?(.done(runID: id, executionCount: message["count"]?.intValue ?? 0))
                }
            case "input_request":
                onEvent?(.inputRequest(prompt: message["prompt"]?.stringValue ?? ""))
            default:
                break
            }
        }
    }

    /// The kernel helper. Protocol: JSON lines; requests on stdin, events on the original stdout
    /// (fd 1 is re-pointed at stderr so stray C-level writes can't corrupt the stream).
    public static let helperSource = #"""
    import ast, base64, builtins, io, json, os, signal, sys, traceback

    _proto = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    _requests = sys.stdin
    _current = [0]
    _count = [0]

    def _emit(message):
        _proto.write(json.dumps(message) + "\n")
        _proto.flush()

    def _output(obj):
        _emit({"type": "output", "id": _current[0], "output": obj})

    class _Stream(io.TextIOBase):
        def __init__(self, name):
            self.name = name
        def writable(self):
            return True
        def write(self, text):
            if text:
                _output({"output_type": "stream", "name": self.name, "text": text})
            return len(text)

    sys.stdout = _Stream("stdout")
    sys.stderr = _Stream("stderr")

    def _input(prompt=""):
        if prompt:
            sys.stdout.write(str(prompt))
        _emit({"type": "input_request", "prompt": str(prompt)})
        while True:
            line = _requests.readline()
            if not line:
                raise EOFError("stdin closed")
            message = json.loads(line)
            if message.get("type") == "input_reply":
                value = message.get("value", "")
                sys.stdout.write(value + "\n")
                return value

    builtins.input = _input
    _ns = {"__name__": "__main__", "__builtins__": builtins}

    # Rich output: the IPython display protocol (_repr_html_, _repr_mimebundle_, …).
    _REPRS = [("text/html", "_repr_html_"), ("text/markdown", "_repr_markdown_"),
              ("text/latex", "_repr_latex_"), ("image/svg+xml", "_repr_svg_"),
              ("image/png", "_repr_png_"), ("image/jpeg", "_repr_jpeg_")]

    def _call_repr(value, name, **kwargs):
        if isinstance(value, type):
            return None  # a class, not an instance: its _repr_*_ are unbound
        try:
            method = getattr(value, name, None)
            result = method(**kwargs) if callable(method) else None
        except Exception:
            return None
        return result[0] if isinstance(result, tuple) and result else result

    def _mimebundle(value):
        data = {}
        bundle = _call_repr(value, "_repr_mimebundle_", include=None, exclude=None)
        if isinstance(bundle, dict):
            data.update({k: v for k, v in bundle.items() if isinstance(v, str) and k in dict(_REPRS)})
        for mime, name in _REPRS:
            if mime in data:
                continue
            result = _call_repr(value, name)
            if isinstance(result, bytes) and mime.startswith("image/") and mime != "image/svg+xml":
                result = base64.b64encode(result).decode("ascii")
            elif isinstance(result, bytes):
                result = result.decode("utf-8", "replace")
            if isinstance(result, str):
                data[mime] = result
        try:
            data["text/plain"] = repr(value)
        except Exception as error:
            data["text/plain"] = "<repr failed: %s>" % type(error).__name__
        return data

    def _display(*objs, raw=False, **kwargs):
        for obj in objs:
            data = obj if raw and isinstance(obj, dict) else _mimebundle(obj)
            _output({"output_type": "display_data", "metadata": {}, "data": data})

    builtins.display = _display
    _real_import = builtins.__import__

    def _import(name, *args, **kwargs):
        module = _real_import(name, *args, **kwargs)
        # Outside an IPython shell, IPython's display() just prints; route it here instead.
        if name.startswith("IPython"):
            for module_name in ("IPython.display", "IPython.core.display_functions", "IPython.core.display"):
                target = sys.modules.get(module_name)
                if target is not None and hasattr(target, "display"):
                    target.display = _display
        return module

    builtins.__import__ = _import

    def _show_figures():
        plt = sys.modules.get("matplotlib.pyplot")
        if plt is None:
            return
        for number in plt.get_fignums():
            figure = plt.figure(number)
            buf = io.BytesIO()
            figure.savefig(buf, format="png", bbox_inches="tight")
            _output({"output_type": "display_data", "metadata": {},
                     "data": {"image/png": base64.b64encode(buf.getvalue()).decode("ascii"),
                              "text/plain": repr(figure)}})
        plt.close("all")

    def _run(code):
        tree = ast.parse(code, "<cell>", "exec")
        last = None
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            last = ast.Expression(tree.body.pop().value)
        exec(compile(tree, "<cell>", "exec"), _ns)
        if last is not None:
            value = eval(compile(last, "<cell>", "eval"), _ns)
            if value is not None:
                _ns["_"] = value
                _output({"output_type": "execute_result", "execution_count": _count[0], "metadata": {},
                         "data": _mimebundle(value)})

    while True:
        try:
            line = _requests.readline()
        except KeyboardInterrupt:
            continue  # interrupt while idle: nothing to stop
        if not line:
            break
        try:
            request = json.loads(line)
        except ValueError:
            continue
        if request.get("type") != "execute":
            continue
        _current[0] = request["id"]
        _count[0] += 1
        try:
            _run(request["code"])
            _show_figures()
        except BaseException as error:
            frames = traceback.format_exception(type(error), error, error.__traceback__)
            # Drop the helper's own frames so tracebacks start at the cell.
            frames = [f for f in frames if "pyide_kernel_" not in f]
            _output({"output_type": "error", "ename": type(error).__name__, "evalue": str(error),
                     "traceback": [f.rstrip("\n") for f in frames]})
        _emit({"type": "done", "id": _current[0], "count": _count[0]})
    """#
}

// MARK: - nbformat-style JSON

public extension JSONValue {
    /// Serializes like Python's `json.dumps(obj, sort_keys=True, indent=1, ensure_ascii=False)`,
    /// which is how Jupyter writes .ipynb files — so saving an unchanged notebook doesn't reformat it.
    func notebookJSON() -> String {
        var out = ""
        write(to: &out, indent: 0)
        return out + "\n"
    }

    private func write(to out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let v): out += v ? "true" : "false"
        case .int(let v): out += String(v)
        case .double(let v):
            out += v.rounded() == v && abs(v) < 1e16 ? String(format: "%.1f", v) : "\(v)"
        case .string(let v): Self.writeString(v, to: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += String(repeating: " ", count: indent + 1)
                item.write(to: &out, indent: indent + 1)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let dict):
            guard !dict.isEmpty else { out += "{}"; return }
            out += "{\n"
            let keys = dict.keys.sorted()
            for (i, key) in keys.enumerated() {
                out += String(repeating: " ", count: indent + 1)
                Self.writeString(key, to: &out)
                out += ": "
                dict[key]!.write(to: &out, indent: indent + 1)
                out += i < keys.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

public extension Notebook {
    /// nbformat stores multi-line text as a list of lines, each keeping its "\n".
    static func sourceLines(_ text: String) -> JSONValue {
        guard !text.isEmpty else { return [] }
        var lines: [JSONValue] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "\n" {
                lines.append(.string(current))
                current = ""
            }
        }
        if !current.isEmpty { lines.append(.string(current)) }
        return .array(lines)
    }
}
