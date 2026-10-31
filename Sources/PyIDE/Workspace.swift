import AppKit
import PyIDECore
import Observation

enum BottomTab: Hashable {
    case problems, output, references, repl, debug
}

/// Where a paused debugger is (normalized path, zero-based line).
struct ExecutionLocation: Equatable {
    let key: String
    let line: Int
}

/// One result of Find References, with its source line for context.
struct ReferenceItem: Identifiable {
    let id = UUID()
    let url: URL
    let position: TextPosition
    let lineText: String
    var fileName: String { url.lastPathComponent }
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

/// A file open in an editor tab.
struct OpenDocument: Identifiable {
    let url: URL
    var text: String
    var isDirty = false
    var version = 1
    /// Normalized path; the identity used for tabs, diagnostics and editor state.
    var id: String { Workspace.key(for: url) }
    var name: String { url.lastPathComponent }
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
    private(set) var documents: [OpenDocument] = []
    private(set) var currentFile: URL? {
        didSet { if oldValue != currentFile { scheduleOutlineRefresh(after: .zero) } }
    }
    /// Symbols of the current file for the Outline sidebar.
    private(set) var outline: [OutlineSymbol] = []
    @ObservationIgnored private var outlineTask: Task<Void, Never>?
    @ObservationIgnored private var fileWatcher: FileWatcher?
    /// Diagnostics per server ("pyright", "ruff"), then per normalized path.
    private(set) var serverDiagnostics: [String: [String: [Diagnostic]]] = [:]

    /// All servers' diagnostics per normalized path, in position order.
    var diagnostics: [String: [Diagnostic]] {
        var merged: [String: [Diagnostic]] = [:]
        for byPath in serverDiagnostics.values {
            for (path, list) in byPath { merged[path, default: []] += list }
        }
        return merged.mapValues { $0.sorted { ($0.start.line, $0.start.character) < ($1.start.line, $1.start.character) } }
    }

    /// A quick-fix menu for the editor to pop up at the caret.
    struct QuickFixMenu: Equatable {
        let id = UUID()
        let offset: Int
        let actions: [CodeAction]
    }
    var quickFixMenu: QuickFixMenu?
    private(set) var lspStatus = "Language server: not started"
    private(set) var interpreter: URL?
    private(set) var output = ""
    private(set) var isRunning = false
    var bottomTab: BottomTab = .problems
    /// Run ruff/black on ⌘S. Persisted across launches.
    var formatOnSave: Bool = UserDefaults.standard.object(forKey: "formatOnSave") as? Bool ?? true {
        didSet { UserDefaults.standard.set(formatOnSave, forKey: "formatOnSave") }
    }
    var revealTarget: RevealTarget?
    private(set) var backStack: [NavigationPoint] = []
    private(set) var references: [ReferenceItem] = []
    private(set) var referencesQuery = ""
    /// UTF-16 caret offset in the current file, reported by the editor.
    @ObservationIgnored var caretOffset = 0
    /// Current editor selection (UTF-16), reported by the editor.
    @ObservationIgnored var selectedRange = NSRange(location: 0, length: 0)

    /// Breakpoints per normalized path: zero-based line → condition ("" when unconditional).
    private(set) var breakpoints: [String: [Int: String]] = [:]
    private(set) var debugSession: DebugSession?
    private(set) var executionLocation: ExecutionLocation?

    private(set) var replOutput = ""
    private(set) var isREPLRunning = false
    @ObservationIgnored private var repl: PythonREPL?

    @ObservationIgnored private var lsp: LSPClient?
    @ObservationIgnored private var lspName = "Language server"
    @ObservationIgnored private var lspReady = false
    /// `ruff server`: lint diagnostics and quick fixes, alongside the main server.
    @ObservationIgnored private var ruff: LSPClient?
    @ObservationIgnored private var ruffReady = false

    /// Servers that should see document open/change/save/close.
    private var syncedServers: [LSPClient] {
        [lspReady ? lsp : nil, ruffReady ? ruff : nil].compactMap { $0 }
    }
    @ObservationIgnored private var runProcess: Process?
    @ObservationIgnored private var runInput: FileHandle?
    @ObservationIgnored private var handledLaunchArguments = false

    var currentDiagnostics: [Diagnostic] {
        guard let currentFile else { return [] }
        let key = Self.key(for: currentFile)
        return serverDiagnostics.values.flatMap { $0[key] ?? [] }
            .sorted { ($0.start.line, $0.start.character) < ($1.start.line, $1.start.character) }
    }

    var allProblems: [ProblemItem] {
        diagnostics.keys.sorted().flatMap { path in
            diagnostics[path, default: []].map { ProblemItem(path: path, diagnostic: $0) }
        }
    }

    private var currentIndex: Int? {
        guard let currentFile else { return nil }
        let key = Self.key(for: currentFile)
        return documents.firstIndex { $0.id == key }
    }

    var text: String { currentIndex.map { documents[$0].text } ?? "" }
    var currentVersion: Int { currentIndex.map { documents[$0].version } ?? 0 }
    var isNotebook: Bool { currentFile?.pathExtension == "ipynb" }
    /// Show a notebook's raw JSON in the text editor instead of the rendered view.
    var showNotebookJSON = false
    var isDirty: Bool { currentIndex.map { documents[$0].isDirty } ?? false }
    var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }
    var currentDocumentID: String { currentFile.map(Self.key(for:)) ?? "" }

    var isPythonFile: Bool { currentFile.map(Self.isPython) ?? false }

    /// Files outside the project (stdlib, typeshed stubs) or inside a virtualenv are opened read-only.
    var isReadOnly: Bool { currentFile.map(isReadOnly) ?? false }

    func isReadOnly(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        let path = Self.key(for: url)
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
        guard confirmDiscardOrSave(documents.filter(\.isDirty)) else { return }
        stopDebugging()
        debugSession = nil
        breakpoints = [:]
        stopREPL()
        replOutput = ""
        await stopLanguageServer()
        rootURL = url
        fileTree = FileNode.loadTree(at: url)
        fileWatcher = FileWatcher(url: url, ignoredComponents: FileNode.ignoredNames.union([".git"])) { [weak self] in
            self?.reloadTree()
        }
        interpreter = PythonEnvironment.interpreter(for: url)
        currentFile = nil
        documents = []
        serverDiagnostics = [:]
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
        if repl != nil { restartREPL() }
        Task { await restartLanguageServer() }
    }

    // MARK: - Files

    /// Opens `url` in a tab (or switches to its existing tab).
    func openFile(_ url: URL) {
        let key = Self.key(for: url)
        if documents.contains(where: { $0.id == key }) {
            currentFile = url
            return
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            appendOutput("Cannot open \(url.path) (not UTF-8 text?)\n")
            bottomTab = .output
            return
        }
        let document = OpenDocument(url: url, text: contents)
        let insertAt = currentIndex.map { $0 + 1 } ?? documents.count
        documents.insert(document, at: insertAt)
        currentFile = url
        caretOffset = 0
        sendDidOpen(document)
    }

    func selectTab(_ document: OpenDocument) {
        currentFile = document.url
    }

    func selectAdjacentTab(_ delta: Int) {
        guard let index = currentIndex, documents.count > 1 else { return }
        let next = (index + delta + documents.count) % documents.count
        currentFile = documents[next].url
    }

    /// Closes a tab, asking to save it first if it has unsaved changes.
    func close(_ document: OpenDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        guard confirmDiscardOrSave([documents[index]]) else { return }
        let closing = documents.remove(at: index)
        sendDidClose(closing)
        for server in serverDiagnostics.keys { serverDiagnostics[server]?.removeValue(forKey: closing.id) }
        if currentFile.map(Self.key(for:)) == closing.id {
            currentFile = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].url
        }
    }

    func closeCurrentTab() {
        if let index = currentIndex { close(documents[index]) }
    }

    func closeOthers(_ keep: OpenDocument) {
        for document in documents where document.id != keep.id { close(document) }
    }

    func closeAll() {
        for document in documents { close(document) }
    }

    func updateText(_ newText: String) {
        guard let index = currentIndex else { return }
        setText(newText, at: index)
    }

    private func setText(_ newText: String, at index: Int) {
        guard documents[index].text != newText else { return }
        // Keep breakpoints on their code as lines are inserted or deleted.
        let key = documents[index].id
        if let lines = breakpoints[key], !lines.isEmpty {
            let moved = LineShift.remap(lines, old: documents[index].text, new: newText)
            if moved != lines { updateBreakpoints(moved, for: key) }
        }
        documents[index].text = newText
        documents[index].isDirty = true
        documents[index].version += 1
        guard Self.isPython(documents[index].url) else { return }
        for server in syncedServers { try? server.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(documents[index].url.absoluteString), "version": .int(documents[index].version)],
            "contentChanges": [["text": .string(newText)]],
        ]) }
        if documents[index].id == currentDocumentID { scheduleOutlineRefresh(after: .milliseconds(500)) }
    }

    /// ⌘S: formats first when Format on Save is on.
    func save() {
        if let index = currentIndex { save(documentID: documents[index].id) }
    }

    /// Save All menu command: like ⌘S for every unsaved document.
    func saveAll() {
        for document in documents where document.isDirty { save(documentID: document.id) }
    }

    /// Saves every unsaved document immediately, without formatting (before runs, on close/quit).
    func saveAllNow() {
        for index in documents.indices where documents[index].isDirty { save(at: index) }
    }

    private func save(documentID id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let url = documents[index].url
        guard formatOnSave, Self.isPython(url), !isReadOnly(url) else {
            save(at: index)
            return
        }
        Task {
            await format(documentID: id, explicit: false)
            if let index = documents.firstIndex(where: { $0.id == id }) { save(at: index) }
        }
    }

    /// Format Document command.
    func formatDocument() { transformCurrentDocument(.format) }

    /// Fix All / Organize Imports (ruff) on the current document.
    func transformCurrentDocument(_ operation: CodeFormatter.Operation) {
        guard let index = currentIndex, !isReadOnly(documents[index].url) else { return }
        let id = documents[index].id
        Task { await format(documentID: id, operation: operation, explicit: true) }
    }

    /// Replaces the document's text with the formatter's output (an undoable edit in the editor).
    private func format(documentID id: String, operation: CodeFormatter.Operation = .format, explicit: Bool) async {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let document = documents[index]
        guard let formatter = CodeFormatter.locate(interpreter: interpreter) else {
            if explicit { flashStatus("No formatter found — uv tool install ruff (or pip install black)") }
            return
        }
        do {
            let formatted = try await formatter.format(
                document.text, file: document.url, operation: operation,
                environment: ToolLocator.environment(interpreter: interpreter), currentDirectory: rootURL)
            // Skip if the user kept typing while the formatter ran.
            guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].text == document.text else { return }
            if formatted.isEmpty && !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            setText(formatted, at: index)
            if explicit && formatted == document.text {
                flashStatus(operation == .format ? "\(formatter.name): already formatted" : "\(operation.title): nothing to change")
            }
        } catch {
            flashStatus(error.localizedDescription)
        }
    }

    @discardableResult
    private func save(at index: Int) -> Bool {
        let document = documents[index]
        guard !isReadOnly(document.url) else { return false }
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            documents[index].isDirty = false
            if Self.isPython(document.url) {
                for server in syncedServers {
                    try? server.notify("textDocument/didSave", params: ["textDocument": ["uri": .string(document.url.absoluteString)]])
                }
            }
            return true
        } catch {
            appendOutput("Save failed: \(error.localizedDescription)\n")
            bottomTab = .output
            return false
        }
    }

    /// For dirty documents about to be closed: asks Save / Don't Save / Cancel.
    /// Returns false if the user cancelled (or a save failed).
    func confirmDiscardOrSave(_ dirty: [OpenDocument]) -> Bool {
        let dirty = dirty.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Do you want to save the changes you made to \(dirty[0].name)?"
            : "Do you want to save the changes to \(dirty.count) files?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for document in dirty {
                guard let index = documents.firstIndex(where: { $0.id == document.id }), save(at: index) else { return false }
            }
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
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

    /// Re-fetches the current file's symbols, debounced while typing.
    private func scheduleOutlineRefresh(after delay: Duration) {
        outlineTask?.cancel()
        outlineTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            guard self.lspReady, self.isPythonFile, let url = self.currentFile, let lsp = self.lsp else {
                self.outline = []
                return
            }
            let result = try? await lsp.request("textDocument/documentSymbol",
                                                params: ["textDocument": ["uri": .string(url.absoluteString)]])
            guard !Task.isCancelled, self.currentFile == url else { return }
            self.outline = result.map(OutlineSymbol.parse) ?? []
        }
    }

    func reveal(_ symbol: OutlineSymbol) {
        revealTarget = RevealTarget(position: symbol.position)
    }

    func signatureHelp(at offset: Int) async -> SignatureInfo? {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/signatureHelp", params: params)
        else { return nil }
        return SignatureInfo.parse(result)
    }

    /// Fills the References panel with every use of the symbol at `offset`.
    func findReferences(at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(at: offset), case .object(var request) = params else { return }
        let ns = text as NSString
        referencesQuery = Identifier.wordRange(in: ns, at: offset).map(ns.substring(with:))
            ?? Identifier.wordRange(in: ns, at: offset - 1).map(ns.substring(with:)) ?? "symbol"
        request["context"] = ["includeDeclaration": true]
        let result = try? await lsp.request("textDocument/references", params: .object(request))
        let locations = result.map(Location.parseAll) ?? []
        var cache: [String: [Substring]] = [:]
        references = locations.compactMap { location -> ReferenceItem? in
            guard let uri = URL(string: location.uri), uri.isFileURL else { return nil }
            let url = URL(fileURLWithPath: uri.path)
            let key = Self.key(for: url)
            if cache[key] == nil {
                let source = documents.first { $0.id == key }?.text ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                cache[key] = source.split(separator: "\n", omittingEmptySubsequences: false)
            }
            let lines = cache[key] ?? []
            let line = lines.indices.contains(location.start.line) ? lines[location.start.line] : ""
            return ReferenceItem(url: url, position: location.start,
                                 lineText: line.trimmingCharacters(in: .whitespaces))
        }
        .sorted { (Self.key(for: $0.url), $0.position.line, $0.position.character)
                < (Self.key(for: $1.url), $1.position.line, $1.position.character) }
        bottomTab = .references
        if references.isEmpty { flashStatus("No references found") }
    }

    func openReference(_ item: ReferenceItem) {
        if let url = currentFile {
            backStack.append(NavigationPoint(url: url, position: LineIndex(text).position(of: caretOffset)))
            if backStack.count > 100 { backStack.removeFirst() }
        }
        navigate(to: item.url, position: item.position)
    }

    /// Prompts for a new name and applies the language server's rename across files.
    /// Changed files that aren't open are opened as unsaved tabs, so nothing is written without ⌘S.
    func renameSymbol(at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(at: offset), case .object(var request) = params else { return }
        let ns = text as NSString
        var oldName = Identifier.wordRange(in: ns, at: offset).map(ns.substring(with:))
            ?? Identifier.wordRange(in: ns, at: offset - 1).map(ns.substring(with:))
        if let prepared = try? await lsp.request("textDocument/prepareRename", params: params) {
            guard let range = PrepareRename.parse(prepared) else {
                flashStatus("Can't rename this symbol")
                return
            }
            oldName = range.placeholder ?? ns.substring(with: LineIndex(text).range(from: range.start, to: range.end))
        }
        guard let oldName, !oldName.isEmpty else {
            flashStatus("Put the caret on a symbol to rename it")
            return
        }
        guard let newName = Self.promptForName(oldName), newName != oldName else { return }
        request["newName"] = .string(newName)
        let result: JSONValue
        do {
            result = try await lsp.request("textDocument/rename", params: .object(request))
        } catch {
            flashStatus("Rename failed: \(error.localizedDescription)")
            return
        }
        let (occurrences, files) = applyWorkspaceEdit(WorkspaceEdit.parse(result))
        flashStatus(files == 0 ? "Nothing to rename"
                    : "Renamed \(occurrences) occurrence\(occurrences == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s") — ⌥⌘S to save")
    }

    private static func promptForName(_ oldName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename '\(oldName)'"
        alert.informativeText = "All references in the project will be updated. Changed files stay unsaved until you save them."
        let field = NSTextField(string: oldName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if Identifier.isValidPythonName(name) { return name }
            alert.informativeText = "'\(name)' is not a valid Python identifier."
        }
        return nil
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
        async let ruffStarted: Void = startRuffServer(root: root)
        await startMainLanguageServer(root: root)
        await ruffStarted
    }

    /// Starts `ruff server` if ruff is installed (in the interpreter's environment or on PATH).
    private func startRuffServer(root: URL) async {
        guard let executable = ToolLocator.find("ruff", in: PythonEnvironment.toolDirectories(for: interpreter)) else { return }
        let client = LSPClient()
        client.onNotification = { method, params in
            Task { @MainActor in
                guard self.ruff === client, method == "textDocument/publishDiagnostics" else { return }
                self.storeDiagnostics(params, server: "ruff")
            }
        }
        client.onExit = { _ in
            Task { @MainActor in
                guard self.ruff === client else { return }
                self.ruff = nil
                self.ruffReady = false
                self.serverDiagnostics["ruff"] = nil
            }
        }
        do {
            try client.start(executable: executable, arguments: ["server"],
                             environment: ToolLocator.environment(interpreter: interpreter), currentDirectory: root)
            ruff = client
            _ = try await client.request("initialize", params: [
                "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
                "clientInfo": ["name": "PyIDE"],
                "rootUri": .string(root.absoluteString),
                "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
                "capabilities": [
                    "textDocument": [
                        "synchronization": ["didSave": true],
                        "publishDiagnostics": [:],
                        "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix", "source"]]]],
                    ],
                    "general": ["positionEncodings": ["utf-16"]],
                ],
            ])
            guard ruff === client else { return }
            try client.notify("initialized", params: [:])
            ruffReady = true
            for document in documents { sendDidOpen(document, to: client) }
        } catch {
            if ruff === client { ruff = nil }
        }
    }

    private func storeDiagnostics(_ params: JSONValue, server: String) {
        guard let published = Diagnostic.parsePublish(params), let url = URL(string: published.uri) else { return }
        let key = Self.key(for: url)
        // Hints ("x is not accessed") are too noisy for the Problems list.
        let shown = published.diagnostics.filter { $0.severity != .hint }
        if shown.isEmpty {
            serverDiagnostics[server]?.removeValue(forKey: key)
        } else {
            serverDiagnostics[server, default: [:]][key] = shown
        }
    }

    // MARK: - Quick fixes

    /// Asks every server for code actions at `offset` and shows them as a menu at the caret.
    func showQuickFixes(at offset: Int) async {
        guard isPythonFile, let url = currentFile else { return }
        let position = LineIndex(text).position(of: offset)
        let line = position.line
        let lineDiagnostics = currentDiagnostics.filter { $0.start.line <= line && line <= $0.end.line }
        var actions: [CodeAction] = []
        for (server, diagnosticSource) in [(lsp, "pyright"), (ruff, "ruff")] {
            guard let server, server === lsp ? lspReady : ruffReady else { continue }
            let own = lineDiagnostics.filter { (serverDiagnostics[diagnosticSource]?[Self.key(for: url)] ?? []).contains($0) }
            let range: JSONValue = own.isEmpty
                ? ["start": position.json, "end": position.json]
                : ["start": own.map(\.start).min { ($0.line, $0.character) < ($1.line, $1.character) }!.json,
                   "end": own.map(\.end).max { ($0.line, $0.character) < ($1.line, $1.character) }!.json]
            let params: JSONValue = [
                "textDocument": ["uri": .string(url.absoluteString)],
                "range": range,
                "context": ["diagnostics": .array(own.compactMap(\.raw))],
            ]
            if let result = try? await server.request("textDocument/codeAction", params: params) {
                actions += CodeAction.parseAll(result)
            }
        }
        // Quick fixes first (preferred on top), then source actions like "Fix all".
        actions.sort { a, b in
            if a.isQuickFix != b.isQuickFix { return a.isQuickFix }
            return a.isPreferred && !b.isPreferred
        }
        guard !actions.isEmpty else {
            flashStatus("No quick fixes here")
            return
        }
        quickFixMenu = QuickFixMenu(offset: offset, actions: actions)
    }

    func apply(_ action: CodeAction) async {
        var edit = action.edit
        if edit == nil, let ruff, ruffReady,
           let resolved = try? await ruff.request("codeAction/resolve", params: action.raw) {
            edit = resolved["edit"].map(WorkspaceEdit.parse)
        }
        guard let edit, !edit.isEmpty else {
            flashStatus("This action can't be applied")
            return
        }
        let (_, files) = applyWorkspaceEdit(edit)
        if files > 1 { flashStatus("Changed \(files) files — ⌥⌘S to save") }
    }

    /// Applies edits to open documents (undoable) and opens other changed files as unsaved tabs.
    @discardableResult
    private func applyWorkspaceEdit(_ changes: [String: [TextEdit]]) -> (occurrences: Int, files: Int) {
        var occurrences = 0, files = 0
        for (uri, edits) in changes.sorted(by: { $0.key < $1.key }) {
            guard let parsed = URL(string: uri), parsed.isFileURL else { continue }
            let url = URL(fileURLWithPath: parsed.path)
            guard !isReadOnly(url) else { continue }
            let key = Self.key(for: url)
            if let index = documents.firstIndex(where: { $0.id == key }) {
                setText(TextEdit.apply(edits, to: documents[index].text), at: index)
            } else {
                guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
                var document = OpenDocument(url: url, text: TextEdit.apply(edits, to: original))
                document.isDirty = true
                documents.append(document)
                sendDidOpen(document)
            }
            occurrences += edits.count
            files += 1
        }
        return (occurrences, files)
    }

    private func startMainLanguageServer(root: URL) async {
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
            scheduleOutlineRefresh(after: .zero)
            for document in documents { sendDidOpen(document, to: client) }
        } catch {
            if lsp === client { lsp = nil }
            lspStatus = "\(spec.name) failed: \(error.localizedDescription)"
        }
    }

    private func stopLanguageServer() async {
        if let ruffClient = ruff {
            ruff = nil
            ruffReady = false
            ruffClient.onNotification = nil
            ruffClient.onExit = nil
            serverDiagnostics["ruff"] = nil
            Task { await ruffClient.shutdown() }
        }
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
            storeDiagnostics(params, server: "pyright")
        case "window/showMessage":
            if let message = params["message"]?.stringValue { lspStatus = "\(lspName): \(message)" }
        default:
            break
        }
    }

    private func sendDidOpen(_ document: OpenDocument) {
        for server in syncedServers { sendDidOpen(document, to: server) }
    }

    private func sendDidOpen(_ document: OpenDocument, to server: LSPClient) {
        guard Self.isPython(document.url) else { return }
        try? server.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": .string(document.url.absoluteString),
                "languageId": "python",
                "version": .int(document.version),
                "text": .string(document.text),
            ],
        ])
    }

    private func sendDidClose(_ document: OpenDocument) {
        guard Self.isPython(document.url) else { return }
        for server in syncedServers {
            try? server.notify("textDocument/didClose", params: ["textDocument": ["uri": .string(document.url.absoluteString)]])
        }
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
            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
            "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix", "source"]]]],
            "references": [:],
            "rename": ["prepareSupport": true],
            "signatureHelp": [
                "signatureInformation": [
                    "documentationFormat": ["markdown", "plaintext"],
                    "parameterInformation": ["labelOffsetSupport": true],
                    "activeParameterSupport": true,
                ],
            ],
        ]
        let workspace: JSONValue = ["configuration": true, "workspaceFolders": true,
                                    "workspaceEdit": ["documentChanges": true]]
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
        saveAllNow()
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
        if isDebugging, runProcess == nil {
            stopDebugging()
            return
        }
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

    // MARK: - Debugging

    var isDebugging: Bool { debugSession?.isActive ?? false }

    var currentBreakpoints: Set<Int> { Set((breakpoints[currentDocumentID] ?? [:]).keys) }

    var currentConditionalBreakpoints: Set<Int> {
        Set((breakpoints[currentDocumentID] ?? [:]).filter { !$0.value.isEmpty }.keys)
    }

    private static func sourceBreakpoints(_ lines: [Int: String]) -> [SourceBreakpoint] {
        lines.map { SourceBreakpoint(line: $0.key + 1, condition: $0.value.isEmpty ? nil : $0.value) }
    }

    private func updateBreakpoints(_ lines: [Int: String], for key: String) {
        breakpoints[key] = lines.isEmpty ? nil : lines
        debugSession?.setBreakpoints(path: key, Self.sourceBreakpoints(lines))
    }

    /// Asks for a Python expression; the breakpoint only pauses when it is true.
    func editBreakpointCondition(line: Int) {
        let key = currentDocumentID
        let alert = NSAlert()
        alert.messageText = "Breakpoint condition (line \(line + 1))"
        alert.informativeText = "Pause only when this Python expression is true. Leave empty to always pause."
        let field = NSTextField(string: breakpoints[key]?[line] ?? "")
        field.placeholderString = "e.g. i == 3"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var lines = breakpoints[key] ?? [:]
        lines[line] = field.stringValue.trimmingCharacters(in: .whitespaces)
        updateBreakpoints(lines, for: key)
    }

    func removeBreakpoint(line: Int) {
        var lines = breakpoints[currentDocumentID] ?? [:]
        lines.removeValue(forKey: line)
        updateBreakpoints(lines, for: currentDocumentID)
    }

    var currentExecutionLine: Int? {
        guard let executionLocation, executionLocation.key == currentDocumentID else { return nil }
        return executionLocation.line
    }

    func toggleBreakpoint(line: Int) {
        guard let currentFile, Self.isPython(currentFile) else { return }
        let key = currentDocumentID
        var lines = breakpoints[key] ?? [:]
        if lines[line] != nil { lines.removeValue(forKey: line) } else { lines[line] = "" }
        updateBreakpoints(lines, for: key)
    }

    func toggleBreakpointAtCaret() {
        toggleBreakpoint(line: LineIndex(text).position(of: caretOffset).line)
    }

    func clearAllBreakpoints() {
        for key in breakpoints.keys { debugSession?.setBreakpoints(path: key, []) }
        breakpoints = [:]
    }

    /// Debugs the current file (or the project's entry point) under debugpy.
    func startDebugging() async {
        guard rootURL != nil, !isDebugging else { return }
        guard let python = interpreter else {
            flashStatus("Python not found — choose an interpreter")
            return
        }
        saveAllNow()
        guard let program = runTarget(), let cwd = rootURL else {
            flashStatus("Nothing to debug: open a .py file (or add main.py)")
            return
        }
        let environment = ToolLocator.environment(interpreter: python)
        let hasOwnDebugpy = await Self.succeeds(python, ["-c", "import debugpy"], environment: environment)
        if !hasOwnDebugpy && !DebugpyLocator.isInstalledInSupportDirectory {
            guard await installDebugpy(python: python) else { return }
        }

        let session = DebugSession(
            breakpoints: breakpoints.mapValues(Self.sourceBreakpoints),
            programName: program.lastPathComponent)
        session.onLocation = { [weak self, weak session] location in
            guard let self, self.debugSession === session else { return }
            guard let (path, line) = location else {
                self.executionLocation = nil
                return
            }
            let url = URL(fileURLWithPath: path)
            self.executionLocation = ExecutionLocation(key: Self.key(for: url), line: max(line - 1, 0))
            self.navigate(to: url, position: TextPosition(line: max(line - 1, 0), character: 0))
            self.bottomTab = .debug
        }
        session.onEnd = { [weak self, weak session] in
            guard let self, self.debugSession === session else { return }
            self.executionLocation = nil
        }
        debugSession = session
        bottomTab = .debug
        session.start(python: python, program: program, cwd: cwd, environment: environment,
                      useSupportDirectory: !hasOwnDebugpy)
    }

    func stopDebugging() {
        debugSession?.stop()
    }

    /// Asks, then installs debugpy into PyIDE's support folder, streaming pip/uv output.
    private func installDebugpy(python: URL) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install debugpy?"
        alert.informativeText = "Debugging uses Microsoft's debugpy. PyIDE can download it from PyPI into "
            + "\(DebugpyLocator.supportDirectory.path) (your project and interpreter are not modified)."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let (executable, arguments) = DebugpyLocator.installCommand(interpreter: python)
        output = "$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n"
        bottomTab = .output
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ToolLocator.environment(interpreter: python)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self.appendOutput(chunk) }
            }
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                Task { @MainActor in self.appendOutput("Failed to run installer: \(error.localizedDescription)\n") }
                continuation.resume(returning: -1)
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let ok = status == 0 && DebugpyLocator.isInstalledInSupportDirectory
        appendOutput(ok ? "\ndebugpy installed.\n" : "\nInstalling debugpy failed (status \(status)).\n")
        return ok
    }

    // MARK: - REPL

    func startREPL() {
        guard repl == nil else { return }
        guard let python = interpreter else {
            replOutput += "Python not found. Choose an interpreter first.\n"
            return
        }
        let session = PythonREPL()
        session.onOutput = { chunk in Task { @MainActor in self.appendREPL(chunk) } }
        session.onExit = { status in
            Task { @MainActor in
                guard self.repl === session else { return }
                self.repl = nil
                self.isREPLRunning = false
                self.appendREPL("\n[REPL exited with status \(status)]\n")
            }
        }
        do {
            try session.start(interpreter: python, environment: ToolLocator.environment(interpreter: python),
                              currentDirectory: rootURL)
            repl = session
            isREPLRunning = true
            appendREPL("# Python REPL — \(python.path)\(rootURL.map { "\n# cwd: \($0.path)" } ?? "")\n")
        } catch {
            appendREPL("Failed to start REPL: \(error.localizedDescription)\n")
        }
    }

    /// Sends one line typed in the REPL panel (echoed, since a piped REPL doesn't echo input).
    func sendREPLLine(_ line: String) {
        if repl == nil { startREPL() }
        appendREPL(line + "\n")
        repl?.send(line)
    }

    /// Sends the editor selection, or the caret's line, to the REPL.
    func sendSelectionToREPL() {
        let ns = text as NSString
        guard ns.length > 0 else { return }
        let selection = NSRange(location: min(selectedRange.location, ns.length),
                                length: min(selectedRange.length, ns.length - min(selectedRange.location, ns.length)))
        let range = selection.length > 0 ? selection : ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let code = PythonREPL.prepareForSending(ns.substring(with: range))
        guard !code.isEmpty else {
            flashStatus("Nothing to send — select code or put the caret on a line")
            return
        }
        bottomTab = .repl
        if repl == nil { startREPL() }
        appendREPL(code)
        repl?.send(code)
    }

    func interruptREPL() { repl?.interrupt() }

    func restartREPL() {
        stopREPL()
        appendREPL("\n# Restarting…\n")
        startREPL()
    }

    func clearREPL() { replOutput = "" }

    private func stopREPL() {
        guard let session = repl else { return }
        repl = nil
        isREPLRunning = false
        session.onExit = nil
        session.stop()
    }

    private func appendREPL(_ s: String) {
        replOutput += s
        if replOutput.utf16.count > 400_000 { replOutput = String(replOutput.suffix(300_000)) }
    }

    // MARK: - Helpers

    nonisolated static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    nonisolated static func isPython(_ url: URL) -> Bool {
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
