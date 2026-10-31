import AppKit
import PyIDECore
import Observation

enum BottomTab: Hashable {
    case problems, output
}

/// A request for the editor to move the caret to a position.
struct RevealTarget: Equatable {
    let id = UUID()
    let position: TextPosition
}

struct NavigationPoint: Equatable {
    let url: URL
    let position: TextPosition
}

struct ProblemItem: Identifiable {
    let path: String
    let diagnostic: Diagnostic
    var id: UUID { diagnostic.id }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// The run-menu actions.
enum RunAction {
    case runFile, test, check
}

/// All state for one open project folder: files, editor buffer, the language server, and python processes.
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var fileTree: [FileNode] = []
    private(set) var currentFile: URL?
    private(set) var text = ""
    private(set) var isDirty = false
    private(set) var diagnostics: [String: [Diagnostic]] = [:]  // keyed by normalized path
    private(set) var lspStatus = "Language server: not started"
    private(set) var interpreter: URL?
    private(set) var output = ""
    private(set) var isRunning = false
    var bottomTab: BottomTab = .problems
    var revealTarget: RevealTarget?
    private(set) var backStack: [NavigationPoint] = []
    /// UTF-16 caret offset in the current file, reported by the editor.
    @ObservationIgnored var caretOffset = 0

    @ObservationIgnored private var lsp: LSPClient?
    @ObservationIgnored private var lspName = "Language server"
    @ObservationIgnored private var lspReady = false
    @ObservationIgnored private var documentVersion = 0
    @ObservationIgnored private var runProcess: Process?
    @ObservationIgnored private var runInput: FileHandle?
    @ObservationIgnored private var handledLaunchArguments = false

    var currentDiagnostics: [Diagnostic] {
        guard let currentFile else { return [] }
        return diagnostics[Self.key(for: currentFile)] ?? []
    }

    var allProblems: [ProblemItem] {
        diagnostics.keys.sorted().flatMap { path in
            diagnostics[path, default: []].map { ProblemItem(path: path, diagnostic: $0) }
        }
    }

    var isPythonFile: Bool { currentFile.map(Self.isPython) ?? false }

    /// Files outside the project (stdlib, typeshed stubs) or inside a virtualenv are opened read-only.
    var isReadOnly: Bool {
        guard let currentFile, let rootURL else { return false }
        let path = Self.key(for: currentFile)
        let root = Self.key(for: rootURL)
        guard path.hasPrefix(root + "/") else { return true }
        let relative = path.dropFirst(root.count + 1)
        return relative.contains("/site-packages/")
            || PythonEnvironment.venvNames.contains { relative.hasPrefix($0 + "/") }
    }

    var canGoBack: Bool { !backStack.isEmpty }

    var interpreterLabel: String {
        guard let interpreter else { return "No Python" }
        if let venv = PythonEnvironment.virtualEnvRoot(of: interpreter) { return "Python (\(venv.lastPathComponent))" }
        return interpreter.path
    }

    // MARK: - Folder

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Python project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFolder(url) }
    }

    /// Opens a folder passed on the command line, e.g. `swift run PyIDE ./Examples/hello`.
    func handleLaunchArguments() async {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        for arg in CommandLine.arguments.dropFirst() {
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: arg).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                await openFolder(url)
                return
            }
        }
    }

    func openFolder(_ url: URL) async {
        if isDirty { save() }
        await stopLanguageServer()
        rootURL = url
        fileTree = FileNode.loadTree(at: url)
        interpreter = PythonEnvironment.interpreter(for: url)
        currentFile = nil
        text = ""
        isDirty = false
        diagnostics = [:]
        output = ""
        backStack = []
        let preferred = ["main.py", "__main__.py", "app.py"].lazy.compactMap { Self.firstFile(named: $0, in: self.fileTree) }.first
        if let first = preferred ?? Self.firstPythonFile(in: fileTree) {
            openFile(first)
        }
        await startLanguageServer(root: url)
    }

    func reloadTree() {
        guard let rootURL else { return }
        fileTree = FileNode.loadTree(at: rootURL)
    }

    func presentInterpreterPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true  // .venv
        panel.treatsFilePackagesAsDirectories = true
        panel.resolvesAliases = false  // keep .venv/bin/python, not the base interpreter it links to
        panel.prompt = "Use Interpreter"
        panel.message = "Choose a Python interpreter (e.g. .venv/bin/python)"
        panel.directoryURL = interpreter?.deletingLastPathComponent() ?? rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            flashStatus("\(url.lastPathComponent) is not executable")
            return
        }
        interpreter = url
        Task { await restartLanguageServer() }
    }

    // MARK: - Files

    func openFile(_ url: URL) {
        guard url != currentFile else { return }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return }
        if isDirty { save() }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            appendOutput("Cannot open \(url.path) (not UTF-8 text?)\n")
            return
        }
        closeCurrentDocument()
        currentFile = url
        text = contents
        isDirty = false
        caretOffset = 0
        documentVersion = 1
        sendDidOpen()
    }

    func updateText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = true
        documentVersion += 1
        guard lspReady, isPythonFile, let url = currentFile else { return }
        try? lsp?.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(url.absoluteString), "version": .int(documentVersion)],
            "contentChanges": [["text": .string(newText)]],
        ])
    }

    func save() {
        guard let url = currentFile, !isReadOnly else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            if lspReady, isPythonFile {
                try? lsp?.notify("textDocument/didSave", params: ["textDocument": ["uri": .string(url.absoluteString)]])
            }
        } catch {
            appendOutput("Save failed: \(error.localizedDescription)\n")
            bottomTab = .output
        }
    }

    func reveal(_ problem: ProblemItem) {
        let url = URL(fileURLWithPath: problem.path)
        if currentFile.map(Self.key(for:)) != problem.path { openFile(url) }
        revealTarget = RevealTarget(position: problem.diagnostic.start)
    }

    // MARK: - Language features

    func completions(at offset: Int) async -> [CompletionItem] {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/completion", params: params)
        else { return [] }
        return CompletionItem.parseList(result)
    }

    func hover(at offset: Int) async -> String? {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/hover", params: params)
        else { return nil }
        return HoverContent.parse(result).map { String($0.prefix(4000)) }
    }

    func jumpToDefinition(at offset: Int) async {
        guard let url = currentFile, case let (lsp, params)? = positionRequest(at: offset) else { return }
        let origin = LineIndex(text).position(of: offset)
        let result = try? await lsp.request("textDocument/definition", params: params)
        guard let location = result.map(Location.parseAll)?.first,
              let target = URL(string: location.uri), target.isFileURL
        else {
            flashStatus("No definition found")
            return
        }
        backStack.append(NavigationPoint(url: url, position: origin))
        if backStack.count > 100 { backStack.removeFirst() }
        navigate(to: URL(fileURLWithPath: target.path), position: location.start)
    }

    func goBack() {
        guard let point = backStack.popLast() else { return }
        navigate(to: point.url, position: point.position)
    }

    private func navigate(to url: URL, position: TextPosition) {
        if currentFile.map(Self.key(for:)) != Self.key(for: url) { openFile(url) }
        guard currentFile.map(Self.key(for:)) == Self.key(for: url) else { return }
        revealTarget = RevealTarget(position: position)
    }

    private func positionRequest(at offset: Int) -> (LSPClient, JSONValue)? {
        guard lspReady, isPythonFile, let url = currentFile, let lsp else { return nil }
        let position = LineIndex(text).position(of: offset)
        return (lsp, ["textDocument": ["uri": .string(url.absoluteString)], "position": position.json])
    }

    private func flashStatus(_ message: String) {
        let previous = lspStatus
        lspStatus = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if lspStatus == message { lspStatus = previous }
        }
    }

    // MARK: - Language server

    func restartLanguageServer() async {
        guard let rootURL else { return }
        await stopLanguageServer()
        await startLanguageServer(root: rootURL)
    }

    private func startLanguageServer(root: URL) async {
        guard let (spec, executable) = LanguageServerSpec.locate(interpreter: interpreter) else {
            lspStatus = "No Python language server — \(LanguageServerSpec.installHint)"
            return
        }
        lspName = spec.name
        let pythonPath = interpreter?.path
        let client = LSPClient()
        client.configurationProvider = { items in
            LanguageServerSpec.configuration(items: items, pythonPath: pythonPath)
        }
        client.onNotification = { method, params in
            Task { @MainActor in self.handleNotification(client, method: method, params: params) }
        }
        client.onExit = { status in
            Task { @MainActor in
                guard self.lsp === client else { return }
                self.lsp = nil
                self.lspReady = false
                self.lspStatus = "\(spec.name) exited (status \(status))"
            }
        }

        do {
            try client.start(executable: executable, arguments: spec.arguments,
                             environment: ToolLocator.environment(interpreter: interpreter), currentDirectory: root)
            lsp = client
            lspStatus = "\(spec.name): starting…"
            _ = try await client.request("initialize", params: Self.initializeParams(root: root))
            guard lsp === client else { return }  // folder changed while initializing
            try client.notify("initialized", params: [:])
            try client.notify("workspace/didChangeConfiguration", params: ["settings": [:]])
            lspReady = true
            lspStatus = "\(spec.name): ready"
            sendDidOpen()
        } catch {
            if lsp === client { lsp = nil }
            lspStatus = "\(spec.name) failed: \(error.localizedDescription)"
        }
    }

    private func stopLanguageServer() async {
        guard let client = lsp else { return }
        lsp = nil
        lspReady = false
        client.onNotification = nil
        client.onExit = nil
        lspStatus = "\(lspName): stopped"
        await client.shutdown()
    }

    private func handleNotification(_ client: LSPClient, method: String, params: JSONValue) {
        guard lsp === client else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let published = Diagnostic.parsePublish(params), let url = URL(string: published.uri) else { return }
            let key = Self.key(for: url)
            // Hints ("x is not accessed") are too noisy for the Problems list.
            let shown = published.diagnostics.filter { $0.severity != .hint }
            if shown.isEmpty {
                diagnostics.removeValue(forKey: key)
            } else {
                diagnostics[key] = shown
            }
        case "window/showMessage":
            if let message = params["message"]?.stringValue { lspStatus = "\(lspName): \(message)" }
        default:
            break
        }
    }

    private func sendDidOpen() {
        guard lspReady, isPythonFile, let url = currentFile else { return }
        try? lsp?.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": .string(url.absoluteString),
                "languageId": "python",
                "version": .int(documentVersion),
                "text": .string(text),
            ],
        ])
    }

    private func closeCurrentDocument() {
        guard lspReady, isPythonFile, let url = currentFile else { return }
        try? lsp?.notify("textDocument/didClose", params: ["textDocument": ["uri": .string(url.absoluteString)]])
    }

    private static func initializeParams(root: URL) -> JSONValue {
        let textDocument: JSONValue = [
            "synchronization": ["didSave": true, "dynamicRegistration": false],
            "publishDiagnostics": ["relatedInformation": false],
            "completion": [
                "completionItem": ["snippetSupport": false, "documentationFormat": ["markdown", "plaintext"]],
            ],
            "hover": ["contentFormat": ["markdown", "plaintext"]],
            "definition": ["linkSupport": false],
        ]
        let workspace: JSONValue = ["configuration": true, "workspaceFolders": true]
        return [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "PyIDE", "version": "0.1.0"],
            "rootUri": .string(root.absoluteString),
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "textDocument": textDocument,
                "workspace": workspace,
                "general": ["positionEncodings": ["utf-16"]],
            ],
        ]
    }

    // MARK: - Run / test / check

    func run(_ action: RunAction) {
        guard rootURL != nil, !isRunning else { return }
        guard let python = interpreter else {
            output = "Python not found. Install it (brew install python) or choose an interpreter.\n"
            bottomTab = .output
            return
        }
        if isDirty { save() }
        let tools = PythonEnvironment.toolDirectories(for: python)

        switch action {
        case .runFile:
            guard let file = runTarget() else {
                output = "Nothing to run: open a .py file (or add main.py).\n"
                bottomTab = .output
                return
            }
            start(python, ["-u", file.path], display: "python \(relativePath(file))")
        case .test:
            Task {
                if await Self.succeeds(python, ["-c", "import pytest"], environment: ToolLocator.environment(interpreter: python)) {
                    start(python, ["-m", "pytest"], display: "python -m pytest")
                } else {
                    start(python, ["-m", "unittest", "discover", "-v"], display: "python -m unittest discover -v")
                }
            }
        case .check:
            if let ruff = ToolLocator.find("ruff", in: tools) {
                start(ruff, ["check", "."], display: "ruff check .")
            } else if let pyright = ToolLocator.find("basedpyright", in: tools) ?? ToolLocator.find("pyright", in: tools) {
                start(pyright, ["--pythonpath", python.path], display: "\(pyright.lastPathComponent)")
            } else {
                start(python, ["-m", "compileall", "-q", "-x", #"(^|/)(\.?venv|\.git|node_modules|build|dist)(/|$)"#, "."],
                      display: "python -m compileall -q .")
            }
        }
    }

    /// The current file if it's a project .py file, else a conventional entry point.
    private func runTarget() -> URL? {
        if let currentFile, isPythonFile, !isReadOnly, currentFile.pathExtension == "py" { return currentFile }
        return ["main.py", "__main__.py", "app.py"].lazy.compactMap { Self.firstFile(named: $0, in: self.fileTree) }.first
    }

    private func start(_ executable: URL, _ arguments: [String], display: String) {
        guard let rootURL, !isRunning else { return }
        output = "$ \(display)\n"
        bottomTab = .output
        isRunning = true

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        process.environment = ToolLocator.environment(interpreter: interpreter)
        let pipe = Pipe(), input = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.appendOutput(chunk) }
        }
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                // Let any final output chunks land first.
                try? await Task.sleep(for: .milliseconds(50))
                self.isRunning = false
                self.runProcess = nil
                try? self.runInput?.close()
                self.runInput = nil
                self.appendOutput("\n[process exited with status \(status)]\n")
            }
        }
        do {
            try process.run()
            runProcess = process
            runInput = input.fileHandleForWriting
        } catch {
            isRunning = false
            appendOutput("Failed to start \(executable.lastPathComponent): \(error.localizedDescription)\n")
        }
    }

    /// Sends a line to the running program's stdin (for `input()`), echoing it in the output.
    func sendInput(_ line: String) {
        guard let runInput else { return }
        appendOutput(line + "\n")
        try? runInput.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Closes the program's stdin (Ctrl-D).
    func sendEOF() {
        try? runInput?.close()
        runInput = nil
    }

    func stopRun() {
        runProcess?.interrupt()  // SIGINT: Python raises KeyboardInterrupt
    }

    private func appendOutput(_ s: String) {
        output += s
    }

    private static func succeeds(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    // MARK: - Helpers

    static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    static func isPython(_ url: URL) -> Bool {
        ["py", "pyi", "pyw"].contains(url.pathExtension)
    }

    func relativePath(_ url: URL) -> String {
        guard let root = rootURL?.path, url.path.hasPrefix(root + "/") else { return url.path }
        return String(url.path.dropFirst(root.count + 1))
    }

    private static func firstFile(named name: String, in nodes: [FileNode]) -> URL? {
        nodes.first(where: { !$0.isDirectory && $0.name == name })?.url
    }

    private static func firstPythonFile(in nodes: [FileNode]) -> URL? {
        nodes.first(where: { !$0.isDirectory && isPython($0.url) })?.url
    }
}
