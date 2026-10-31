import AppKit
import PyIDECore
import SwiftUI

/// An editable, runnable Jupyter notebook: code cells run in a per-notebook kernel.
struct NotebookView: View {
    @Environment(Workspace.self) private var workspace
    let documentID: String
    let version: Int

    var body: some View {
        // Re-resolve when the document changes from outside (e.g. edited as JSON).
        let _ = version
        switch workspace.notebookModel() {
        case .success(let model):
            NotebookEditor(model: model)
                .id(ObjectIdentifier(model))
        case .failure(let error):
            VStack(spacing: 8) {
                Text(error.localizedDescription).foregroundStyle(.secondary)
                Text("Use “Show JSON” to edit the file directly.").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            EmptyView()
        }
    }
}

struct NotebookEditor: View {
    @Environment(Workspace.self) private var workspace
    let model: NotebookModel
    private var readOnly: Bool { workspace.isReadOnly }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.cells) { cell in
                            CellView(model: model, cell: cell, readOnly: readOnly,
                                     run: { advance in run(cell.id, advance: advance) })
                                .id(cell.id)
                        }
                        if !readOnly {
                            HStack(spacing: 12) {
                                Button("+ Code") { model.insertCell(.code, after: model.cells.last?.id) }
                                Button("+ Markdown") { model.insertCell(.markdown, after: model.cells.last?.id) }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .padding(.leading, 48)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 940, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.selectedCellID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { workspace.runAllCells(in: model) } label: { Label("Run All", systemImage: "forward.fill") }
                .disabled(readOnly)
            Button { workspace.interruptKernel(for: model) } label: { Label("Interrupt", systemImage: "stop.fill") }
                .disabled(model.kernelStatus != .busy)
            Button { workspace.restartKernel(for: model) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(readOnly)
            Button { model.clearOutputs() } label: { Label("Clear Outputs", systemImage: "eraser") }
                .disabled(readOnly)
            Spacer()
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var statusText: String {
        switch model.kernelStatus {
        case .none: "No kernel — runs with \(workspace.interpreterLabel)"
        case .starting: "Starting…"
        case .idle: "Kernel idle"
        case .busy: "Kernel busy"
        case .dead(let message): message
        }
    }

    private var statusColor: Color {
        switch model.kernelStatus {
        case .none: .gray
        case .starting, .busy: .orange
        case .idle: .green
        case .dead: .red
        }
    }

    /// Runs a cell; with `advance`, selects the next cell (adding one at the end, like Jupyter).
    private func run(_ id: UUID, advance: Bool) {
        guard let index = model.index(of: id) else { return }
        if model.cells[index].kind == .code { workspace.runCells([id], in: model) }
        guard advance else { return }
        if index + 1 < model.cells.count {
            model.selectedCellID = model.cells[index + 1].id
        } else {
            model.insertCell(.code, after: id)
        }
    }
}

struct CellView: View {
    @Environment(Workspace.self) private var workspace
    let model: NotebookModel
    let cell: NotebookModel.Cell
    let readOnly: Bool
    let run: (_ advance: Bool) -> Void
    @State private var hovering = false
    @State private var editingMarkdown = false

    private var isSelected: Bool { model.selectedCellID == cell.id }

    private func complete(_ id: UUID, _ offset: Int) async -> [CompletionItem] {
        await workspace.notebookCompletions(in: model, cell: id, offset: offset)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(prompt)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(cell.state == .idle ? .tertiary : .secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                content
                ForEach(Array(cell.outputs.enumerated()), id: \.offset) { _, output in
                    if let parsed = Notebook.parseOutput(output) { NotebookOutputView(output: parsed) }
                }
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .topTrailing) { if (hovering || isSelected) && !readOnly { cellToolbar } }
        .overlay(alignment: .leading) {
            if isSelected { RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 3).offset(x: -10) }
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCellID = cell.id }
    }

    private var prompt: String {
        guard cell.kind == .code else { return "" }
        switch cell.state {
        case .queued, .running: return "[*]"
        case .idle: return cell.executionCount.map { "[\($0)]" } ?? "[ ]"
        }
    }

    @ViewBuilder private var content: some View {
        switch cell.kind {
        case .code:
            CellEditor(text: cell.source, highlight: model.language == "python", editable: !readOnly,
                       focused: isSelected,
                       onChange: { model.setSource($0, of: cell.id) },
                       onRun: run,
                       onFocus: { model.selectedCellID = cell.id },
                       complete: model.language == "python" ? { offset in
                           await complete(cell.id, offset)
                       } : nil)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))
        case .markdown where editingMarkdown || cell.source.isEmpty:
            CellEditor(text: cell.source, highlight: false, editable: !readOnly, focused: isSelected,
                       onChange: { model.setSource($0, of: cell.id) },
                       onRun: { advance in
                           editingMarkdown = false
                           run(advance)
                       },
                       onFocus: { model.selectedCellID = cell.id })
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        case .markdown:
            MarkdownCell(source: cell.source)
                .padding(.horizontal, 4)
                .onTapGesture(count: 2) { if !readOnly { editingMarkdown = true } }
                .help("Double-click to edit")
        case .raw:
            Text(cell.source)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var cellToolbar: some View {
        HStack(spacing: 8) {
            if cell.kind == .code {
                Button { run(false) } label: { Image(systemName: "play.fill") }.help("Run cell (⇧↩)")
            }
            Button { model.moveCell(cell.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Move up")
            Button { model.moveCell(cell.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Move down")
            Button { model.insertCell(.code, after: cell.id) } label: { Image(systemName: "plus") }.help("Add code cell below")
            Menu {
                Button("Code") { model.setKind(.code, of: cell.id) }
                Button("Markdown") { model.setKind(.markdown, of: cell.id) }
                Button("Raw") { model.setKind(.raw, of: cell.id) }
            } label: { Text(cell.kind == .code ? "Code" : cell.kind == .markdown ? "Markdown" : "Raw") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            Button { model.deleteCell(cell.id) } label: { Image(systemName: "trash") }.help("Delete cell")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.bar, in: RoundedRectangle(cornerRadius: 5))
        .offset(y: -10)
    }
}

/// Renders one cell output.
struct NotebookOutputView: View {
    let output: Notebook.Output

    var body: some View {
        switch output {
        case .text(let text, let isError):
            Text(text.trimmingCharacters(in: .newlines))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 800), alignment: .leading)
                    .padding(.horizontal, 8)
            }
        case .error(let name, let value, let traceback):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name): \(value)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                if !traceback.isEmpty {
                    Text(traceback).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// A self-sizing NSTextView for one cell, with Python highlighting and indentation.
struct CellEditor: NSViewRepresentable {
    var text: String
    var highlight: Bool
    var editable: Bool
    var focused: Bool
    var onChange: (String) -> Void
    var onRun: (_ advance: Bool) -> Void
    var onFocus: () -> Void
    /// Completions at a UTF-16 offset in this cell (nil: no completion, e.g. markdown).
    var complete: ((Int) async -> [CompletionItem])?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CellTextView {
        let view = CellTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = EditorTheme.font
        view.typingAttributes = EditorTheme.baseAttributes
        view.defaultParagraphStyle = EditorTheme.paragraphStyle
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 2)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isEditable = editable
        view.string = text
        view.onRun = { advance in context.coordinator.parent.onRun(advance) }
        view.onFocus = { context.coordinator.parent.onFocus() }
        view.onBlur = { context.coordinator.hideCompletions() }
        context.coordinator.restyle(view)
        return view
    }

    func updateNSView(_ view: CellTextView, context: Context) {
        context.coordinator.parent = self
        if view.isEditable != editable { view.isEditable = editable }
        if view.string != text {
            view.string = text
            context.coordinator.restyle(view)
        }
        if focused, view.window != nil, view.window?.firstResponder !== view, context.coordinator.lastFocused != true {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        context.coordinator.lastFocused = focused
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CellTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(width - view.textContainerInset.width * 2, 10),
                                         height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: EditorTheme.font)
        let height = max(layout.usedRect(for: container).height, lineHeight) + view.textContainerInset.height * 2
        return CGSize(width: width, height: ceil(height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CellEditor
        var lastFocused: Bool?
        private let popup = CompletionPopup()
        private var items: [CompletionItem] = []
        private var completionTask: Task<Void, Never>?
        private var lastReplacement: String?
        private weak var textView: NSTextView?

        init(_ parent: CellEditor) {
            self.parent = parent
            super.init()
            popup.onAccept = { [weak self] item in self?.accept(item) }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            lastReplacement = replacementString
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CellTextView else { return }
            textView = view
            restyle(view)
            parent.onChange(view.string)

            let typed = lastReplacement
            lastReplacement = nil
            guard parent.complete != nil else { return }
            if let typed, typed.utf16.count == 1, let unit = typed.utf16.first, unit == 0x2E || Identifier.isIdentifier(unit) {
                if unit == 0x2E {
                    items = []
                    popup.hide()
                    scheduleCompletion(in: view, after: .zero)
                } else {
                    refilter(in: view)
                    scheduleCompletion(in: view, after: .milliseconds(80))
                }
            } else if typed == "", popup.isVisible {
                refilter(in: view)
            } else {
                hideCompletions()
            }
        }

        private func scheduleCompletion(in view: NSTextView, after delay: Duration) {
            completionTask?.cancel()
            completionTask = Task { [weak self, weak view] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let view, let complete = self.parent.complete else { return }
                let results = await complete(view.selectedRange().location)
                guard !Task.isCancelled else { return }
                self.items = results
                self.refilter(in: view)
            }
        }

        private func refilter(in view: NSTextView) {
            guard let window = view.window, !items.isEmpty else {
                popup.hide()
                return
            }
            let ns = view.string as NSString
            let caret = view.selectedRange().location
            let start = Identifier.prefixStart(in: ns, before: caret)
            let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
            if let first = prefix.utf16.first, !Identifier.isIdentifierStart(first) {
                popup.hide()
                return
            }
            let matches = items.filter { FuzzyMatch.matches(prefix, $0.filterText) }
            if matches.isEmpty || (matches.count == 1 && matches[0].insertText == prefix) {
                popup.hide()
                return
            }
            let anchor = view.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            popup.show(matches, below: anchor, in: window)
        }

        func hideCompletions() {
            completionTask?.cancel()
            completionTask = nil
            items = []
            popup.hide()
        }

        private func accept(_ item: CompletionItem) {
            guard let view = textView else { return }
            hideCompletions()
            let caret = view.selectedRange().location
            let start = Identifier.prefixStart(in: view.string as NSString, before: caret)
            view.insertText(item.insertText, replacementRange: NSRange(location: start, length: caret - start))
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            self.textView = textView
            if popup.isVisible {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    popup.moveSelection(by: -1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    popup.moveSelection(by: 1)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if let item = popup.selectedItem { accept(item) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    hideCompletions()
                    return true
                case #selector(NSResponder.deleteBackward(_:)):
                    return false
                default:
                    hideCompletions()
                }
            }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                if parent.complete != nil, textView.isEditable { scheduleCompletion(in: textView, after: .zero) }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let ns = textView.string as NSString
                let selection = textView.selectedRange()
                let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
                let before = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
                textView.insertText("\n" + (parent.highlight ? PythonIndent.indentAfter(line: before) : ""),
                                    replacementRange: selection)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText(PythonIndent.unit, replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }

        func restyle(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            storage.beginEditing()
            storage.setAttributes(EditorTheme.baseAttributes, range: NSRange(location: 0, length: storage.length))
            if parent.highlight {
                for token in PythonHighlighter.tokenize(view.string) {
                    storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: token.range)
                }
            }
            storage.endEditing()
        }
    }
}

final class CellTextView: NSTextView {
    var onRun: ((Bool) -> Void)?
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onBlur?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {  // Return / Enter
            if flags == .shift { onRun?(true); return }       // ⇧↩ run and advance
            if flags == .command { onRun?(false); return }    // ⌘↩ run in place
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

/// Block-level markdown good enough for notebooks: headings, bullets, fenced code, paragraphs.
struct MarkdownCell: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .title3.bold())
                        .padding(.top, level == 1 ? 4 : 2)
                case .code(let text):
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(Self.inline(text))
                    }
                case .paragraph(let text):
                    Text(Self.inline(text))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case heading(Int, String), code(String), bullet(String), paragraph(String)
    }

    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
                      trimmed[hashes] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level, String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
