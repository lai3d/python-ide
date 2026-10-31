import PyIDECore
import SwiftUI

/// Bottom-panel debugger UI: controls, call stack, variables, and a console with evaluation.
struct DebugPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let session = workspace.debugSession {
            HSplitView {
                VStack(spacing: 0) {
                    DebugControls(session: session)
                    Divider()
                    CallStackList(session: session)
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                VariablesTree(session: session)
                    .frame(minWidth: 220, idealWidth: 320)
                DebugConsole(session: session)
                    .frame(minWidth: 220)
            }
        } else {
            VStack(spacing: 8) {
                Text("Not debugging").foregroundStyle(.secondary)
                Text("Click a line number to set a breakpoint, then Debug (⇧⌘D).")
                    .font(.caption).foregroundStyle(.tertiary)
                Button("Debug Current File") { Task { await workspace.startDebugging() } }
                    .disabled(workspace.rootURL == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DebugControls: View {
    @Environment(Workspace.self) private var workspace
    let session: DebugSession

    var body: some View {
        HStack(spacing: 10) {
            if session.isStopped {
                button("Continue (⌃⌘Y)", "play.fill") { session.resume() }
            } else {
                button("Pause", "pause.fill") { session.pause() }.disabled(session.state != .running)
            }
            button("Step Over (F6)", "arrow.turn.down.right") { session.stepOver() }.disabled(!session.isStopped)
            button("Step Into (F7)", "arrow.down.to.line") { session.stepIn() }.disabled(!session.isStopped)
            button("Step Out (F8)", "arrow.up.to.line") { session.stepOut() }.disabled(!session.isStopped)
            if session.isActive {
                button("Stop (⌘.)", "stop.fill") { workspace.stopDebugging() }
            } else {
                button("Debug Again (⇧⌘D)", "arrow.clockwise") { Task { await workspace.startDebugging() } }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func button(_ help: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

struct CallStackList: View {
    let session: DebugSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(session.isStopped ? .orange : .secondary)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            List(session.frames, selection: Binding(
                get: { session.selectedFrameID },
                set: { id in if let frame = session.frames.first(where: { $0.id == id }) { session.select(frame: frame) } })
            ) { frame in
                VStack(alignment: .leading, spacing: 1) {
                    Text(frame.name).font(.system(.callout, design: .monospaced)).lineLimit(1)
                    Text("\(frame.path.map { ($0 as NSString).lastPathComponent } ?? "?"):\(frame.line)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(frame.id)
                .opacity(frame.path == nil ? 0.5 : 1)
            }
            .listStyle(.plain)
        }
    }

    private var status: String {
        switch session.state {
        case .starting: "Starting \(session.programName)…"
        case .running: "Running \(session.programName)"
        case .stopped: session.stopDescription
        case .ended: "Session ended"
        }
    }
}

struct VariablesTree: View {
    @Environment(Workspace.self) private var workspace
    let session: DebugSession
    @State private var newWatch = ""

    var body: some View {
        List {
            Section("Watch") {
                ForEach(session.watchExpressions, id: \.self) { expression in
                    HStack(spacing: 6) {
                        Text(expression).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
                        Text(session.watchValues[expression] ?? (session.isStopped ? "…" : "—"))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle((session.watchValues[expression] ?? "").hasPrefix("⚠︎") ? .orange : .secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button { workspace.removeWatch(expression) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                            .help("Remove watch")
                    }
                }
                TextField("Add watch expression", text: $newWatch)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit {
                        workspace.addWatch(newWatch)
                        newWatch = ""
                    }
            }
            Section("Variables") {
                if session.scopes.isEmpty {
                    Text(session.isStopped ? "No variables" : "Variables appear when paused")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(session.scopes.enumerated()), id: \.element.id) { index, scope in
                    VariableNode(variable: scope, session: session, initiallyExpanded: index == 0)
                }
            }
        }
        .listStyle(.sidebar)
        .id(session.stopCount)  // references are only valid for the current stop
    }
}

struct VariableNode: View {
    let variable: VariableInfo
    let session: DebugSession
    var initiallyExpanded = false
    @State private var expanded: Bool?
    @State private var children: [VariableInfo]?

    var body: some View {
        if variable.reference > 0 {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded ?? initiallyExpanded },
                set: { expanded = $0 })
            ) {
                if let children {
                    ForEach(children) { VariableNode(variable: $0, session: session) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                row
            }
            .task(id: expanded ?? initiallyExpanded) {
                if expanded ?? initiallyExpanded, children == nil {
                    children = await session.children(of: variable.reference)
                }
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Text(variable.name).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
            if !variable.value.isEmpty {
                Text(variable.value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let type = variable.type, !type.isEmpty {
                Text(type).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
        .help("\(variable.name) = \(variable.value)")
    }
}

struct DebugConsole: View {
    let session: DebugSession
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.console.isEmpty ? "Program output and evaluation results appear here." : session.console)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(session.console.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: session.console) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            HStack(spacing: 6) {
                Text(session.isStopped ? ">>>" : "›").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                TextField(session.isStopped ? "Evaluate in the selected frame" : "Input for the program (stdin)", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit {
                        session.submitConsoleInput(input)
                        input = ""
                    }
                    .disabled(!session.isActive)
                if session.isActive && !session.isStopped {
                    Button("EOF") { session.sendEOF() }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Close the program's stdin (Ctrl-D)")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}
