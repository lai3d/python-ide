import PyIDECore
import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        NavigationSplitView {
            FileTreeView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            if workspace.rootURL == nil {
                WelcomeView()
            } else {
                EditorArea()
            }
        }
        .navigationTitle(workspace.rootURL?.lastPathComponent ?? "PyIDE")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.run(.check) } label: {
                    Label("Check", systemImage: "checkmark.seal")
                }
                .help("Lint: ruff check / pyright (⌘B)")
                Button { workspace.run(.test) } label: {
                    Label("Test", systemImage: "checkmark.diamond")
                }
                .help("pytest or unittest (⌘U)")
                Button { workspace.run(.runFile) } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .help("Run the current file (⌘R)")
                Button { workspace.stopRun() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop (⌘.)")
                .disabled(!workspace.isRunning)
            }
        }
        .task { await workspace.handleLaunchArguments() }
    }
}

struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("PyIDE").font(.largeTitle.bold())
            Text("Open a Python project folder to get started.")
                .foregroundStyle(.secondary)
            Button("Open Folder…") { workspace.presentOpenPanel() }
                .keyboardShortcut("o")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileTreeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let selection = Binding<URL?>(
            get: { workspace.currentFile },
            set: { if let url = $0 { workspace.openFile(url) } })

        List(workspace.fileTree, children: \.children, selection: selection) { node in
            Label(node.name, systemImage: Self.icon(for: node))
                .lineLimit(1)
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("Reload") { workspace.reloadTree() }
        }
    }

    private static func icon(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension {
        case "py", "pyi", "pyw": return "doc.text"
        case "toml", "cfg", "ini", "lock": return "shippingbox"
        case "ipynb": return "book"
        case "md": return "doc.richtext"
        default: return "doc"
        }
    }
}

struct EditorArea: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                EditorHeader()
                Divider()
                if workspace.currentFile != nil {
                    CodeEditorView(
                        text: workspace.text,
                        highlightCode: workspace.isPythonFile,
                        isEditable: !workspace.isReadOnly,
                        diagnostics: workspace.currentDiagnostics,
                        reveal: workspace.revealTarget,
                        services: EditorServices(
                            completions: { await workspace.completions(at: $0) },
                            hover: { await workspace.hover(at: $0) },
                            definition: { offset in Task { await workspace.jumpToDefinition(at: offset) } },
                            caretMoved: { workspace.caretOffset = $0 }),
                        onChange: { workspace.updateText($0) })
                } else {
                    Text("Select a file")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 200)

            BottomPanel()
                .frame(minHeight: 100, idealHeight: 180)
        }
    }
}

struct EditorHeader: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            Button { workspace.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!workspace.canGoBack)
                .help("Go Back (⌃⌘←)")
            if let file = workspace.currentFile {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(file.lastPathComponent).fontWeight(.medium)
                if workspace.isReadOnly {
                    Text("Read Only")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if workspace.isDirty {
                    Circle().fill(.secondary).frame(width: 7, height: 7).help("Unsaved changes")
                }
                Spacer()
                Text(relativePath(file)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func relativePath(_ url: URL) -> String { workspace.relativePath(url) }
}

struct BottomPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $workspace.bottomTab) {
                    Text("Problems (\(workspace.allProblems.count))").tag(BottomTab.problems)
                    Text("Output").tag(BottomTab.output)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if workspace.isRunning { ProgressView().controlSize(.small) }
                Button { workspace.presentInterpreterPanel() } label: {
                    Label(workspace.interpreterLabel, systemImage: "terminal")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.borderless)
                .help(workspace.interpreter?.path ?? "Choose a Python interpreter")
                Divider().frame(height: 12)
                Text(workspace.lspStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch workspace.bottomTab {
            case .problems: ProblemsList()
            case .output: OutputView()
            }
        }
    }
}

struct ProblemsList: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let problems = workspace.allProblems
        if problems.isEmpty {
            Text("No problems")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(problems) { item in
                Button { workspace.reveal(item) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(item.diagnostic.severity))
                            .foregroundStyle(Self.color(item.diagnostic.severity))
                        Text("\(item.fileName):\(item.diagnostic.start.line + 1):\(item.diagnostic.start.character + 1)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.diagnostic.message)
                            .lineLimit(2)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

extension ProblemsList {
    static func symbol(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    static func color(_ severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .yellow
        default: .blue
        }
    }
}

struct OutputView: View {
    @Environment(Workspace.self) private var workspace
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(workspace.output.isEmpty ? "No output yet. Use Run (⌘R), Test (⌘U) or Check (⌘B)." : workspace.output)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(workspace.output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: workspace.output) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            if workspace.isRunning {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    TextField("stdin — type input for the program and press ↩", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($inputFocused)
                        .onSubmit {
                            workspace.sendInput(input)
                            input = ""
                            inputFocused = true
                        }
                    Button("EOF") { workspace.sendEOF() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Close stdin (Ctrl-D)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
    }
}
