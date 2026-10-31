import AppKit
import PyIDECore
import SwiftUI

/// Language-server hooks the editor calls into. Offsets are UTF-16 offsets in the buffer.
struct EditorServices {
    var completions: @MainActor (Int) async -> [CompletionItem]
    var hover: @MainActor (Int) async -> String?
    var signatureHelp: @MainActor (Int) async -> SignatureInfo?
    var definition: @MainActor (Int) -> Void
    var references: @MainActor (Int) -> Void
    var rename: @MainActor (Int) -> Void
    /// Zero-based line clicked in the gutter.
    var toggleBreakpoint: @MainActor (Int) -> Void
    var quickFix: @MainActor (Int) -> Void = { _ in }
    var applyCodeAction: @MainActor (CodeAction) -> Void = { _ in }
    var editBreakpointCondition: @MainActor (Int) -> Void = { _ in }
    var editLogMessage: @MainActor (Int) -> Void = { _ in }
    var editHitCount: @MainActor (Int) -> Void = { _ in }
    var removeBreakpoint: @MainActor (Int) -> Void = { _ in }
    var caretMoved: @MainActor (NSRange) -> Void
}

/// An NSTextView-based code editor with Python highlighting and indentation, diagnostics,
/// completion (type or Esc), hover info, and ⌘-click go-to-definition.
struct CodeEditorView: NSViewRepresentable {
    /// Identifies the open document; each one keeps its own caret, scroll position and undo history.
    var documentID: String
    /// All open documents, so state for closed ones can be dropped.
    var openDocumentIDs: Set<String>
    var text: String
    var highlightCode: Bool
    var isEditable: Bool
    var diagnostics: [Diagnostic]
    var breakpointLines: Set<Int> = []
    var conditionalBreakpointLines: Set<Int> = []
    var logpointLines: Set<Int> = []
    /// Zero-based line where the debugger is paused in this document.
    var executionLine: Int?
    var quickFixMenu: Workspace.QuickFixMenu?
    var reveal: RevealTarget?
    var services: EditorServices
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let big = CGFloat.greatestFiniteMagnitude
        // TextKit 1: the line-number ruler lays out against NSLayoutManager.
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: big, height: big)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true  // no soft wrap: code scrolls horizontally
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: big, height: big)

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = EditorTheme.font
        textView.typingAttributes = EditorTheme.baseAttributes
        textView.defaultParagraphStyle = EditorTheme.paragraphStyle
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.isEditable = isEditable

        let coordinator = context.coordinator
        textView.onMouseMoved = { [weak coordinator] index in coordinator?.mouseMoved(to: index) }
        textView.onMouseExited = { [weak coordinator] in coordinator?.endHover() }
        textView.onMouseDown = { [weak coordinator] in coordinator?.dismissPopups() }
        textView.onCommandClick = { [weak coordinator] index in coordinator?.commandClick(at: index) }
        textView.onToggleComment = { [weak coordinator] in coordinator?.toggleComment() }

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        ruler.onToggleBreakpoint = { [weak coordinator] line in coordinator?.parent.services.toggleBreakpoint(line) }
        ruler.onEditCondition = { [weak coordinator] line in coordinator?.parent.services.editBreakpointCondition(line) }
        ruler.onEditLogMessage = { [weak coordinator] line in coordinator?.parent.services.editLogMessage(line) }
        ruler.onEditHitCount = { [weak coordinator] line in coordinator?.parent.services.editHitCount(line) }
        ruler.onRemoveBreakpoint = { [weak coordinator] line in coordinator?.parent.services.removeBreakpoint(line) }
        coordinator.textView = textView
        coordinator.ruler = ruler
        coordinator.documentID = documentID
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        ruler.textDidChange()
        coordinator.applyStyling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }

        coordinator.retainDocuments(openDocumentIDs.union([documentID]))
        if coordinator.documentID != documentID {
            coordinator.switchDocument(to: documentID, text: text)
        } else if textView.string != text {
            // Replaced from outside (e.g. reloaded); typing never gets here since text already matches.
            coordinator.replaceText(text)
        } else if coordinator.appliedDiagnostics != diagnostics || coordinator.appliedHighlightCode != highlightCode
                    || coordinator.appliedExecutionLine != executionLine {
            coordinator.applyStyling()
        }

        if let menu = quickFixMenu, menu.id != coordinator.lastQuickFixID {
            coordinator.lastQuickFixID = menu.id
            coordinator.showQuickFixMenu(menu)
        }

        coordinator.ruler?.setDebugState(breakpoints: breakpointLines, conditional: conditionalBreakpointLines,
                                         logpoints: logpointLines,
                                         executionLine: executionLine)

        if let reveal, reveal.id != coordinator.lastRevealID {
            coordinator.lastRevealID = reveal.id
            let index = LineIndex(textView.string)
            let location = index.offset(of: reveal.position)
            let word = Identifier.wordRange(in: textView.string as NSString, at: location)
                ?? NSRange(location: location, length: 0)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(word)
            textView.window?.makeFirstResponder(textView)
            if word.length > 0 { textView.showFindIndicator(for: word) }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismissPopups()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: CodeTextView?
        var appliedDiagnostics: [Diagnostic] = []
        var appliedHighlightCode = false
        var appliedExecutionLine: Int?
        var lastQuickFixID: UUID?

        /// Pops up the code actions just below the caret line.
        func showQuickFixMenu(_ quickFix: Workspace.QuickFixMenu) {
            guard let textView else { return }
            dismissPopups()
            let menu = NSMenu()
            var lastWasQuickFix = quickFix.actions.first?.isQuickFix ?? true
            for action in quickFix.actions {
                if action.isQuickFix != lastWasQuickFix { menu.addItem(.separator()) }
                lastWasQuickFix = action.isQuickFix
                let item = ClosureMenuItem(action.title) { [weak self] in self?.parent.services.applyCodeAction(action) }
                if action.isPreferred { item.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "preferred") }
                menu.addItem(item)
            }
            let length = (textView.string as NSString).length
            let range = NSRange(location: min(quickFix.offset, length), length: 0)
            guard let window = textView.window else { return }
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let windowRect = window.convertFromScreen(screenRect)
            let point = textView.convert(NSPoint(x: windowRect.minX, y: windowRect.minY), from: nil)
            menu.popUp(positioning: nil, at: point, in: textView)
        }
        var lastRevealID: UUID?
        weak var ruler: LineNumberRuler?
        var documentID = ""

        /// Per-document editor state, restored when switching tabs.
        private struct ViewState {
            var selection: NSRange
            var scrollOrigin: NSPoint
            /// The text when the tab was left; if it changed meanwhile, its undo history is stale.
            var text: String
        }
        private var viewStates: [String: ViewState] = [:]
        private var undoManagers: [String: UndoManager] = [:]

        private let completionPopup = CompletionPopup()
        private var completionItems: [CompletionItem] = []
        private var completionTask: Task<Void, Never>?
        private var lastReplacement: String?
        private var isApplyingCompletion = false

        private let signaturePopup = SignaturePopup()
        private var signatureTask: Task<Void, Never>?
        private var signatureLineStart: Int?

        private var hoverTask: Task<Void, Never>?
        private var hoverWord: NSRange?
        private var hoverPopover: NSPopover?

        init(_ parent: CodeEditorView) {
            self.parent = parent
            super.init()
            completionPopup.onAccept = { [weak self] item in self?.accept(item) }
        }

        // MARK: Documents

        func undoManager(for view: NSTextView) -> UndoManager? {
            if let manager = undoManagers[documentID] { return manager }
            let manager = UndoManager()
            undoManagers[documentID] = manager
            return manager
        }

        func switchDocument(to id: String, text: String) {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            dismissPopups()
            viewStates[documentID] = ViewState(selection: textView.selectedRange(),
                                               scrollOrigin: scrollView.contentView.bounds.origin,
                                               text: textView.string)
            documentID = id
            textView.string = text
            ruler?.textDidChange()
            applyStyling()
            let length = (text as NSString).length
            if let state = viewStates[id], state.text != text {
                // Changed while in the background (e.g. Save All formatted it).
                undoManagers[id]?.removeAllActions()
            }
            if let state = viewStates[id], NSMaxRange(state.selection) <= length {
                textView.setSelectedRange(state.selection)
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                scrollView.contentView.scroll(to: state.scrollOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                (scrollView as? EditorScrollView)?.scrollToTopLeft() ?? textView.scrollToBeginningOfDocument(nil)
            }
        }

        /// Forgets state for documents that are no longer open.
        func retainDocuments(_ ids: Set<String>) {
            viewStates = viewStates.filter { ids.contains($0.key) }
            undoManagers = undoManagers.filter { ids.contains($0.key) }
        }

        /// Replaces the whole buffer (e.g. with formatter output) as one undoable edit,
        /// keeping the caret on the same line/column and the scroll position.
        func replaceText(_ text: String) {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            dismissPopups()
            let old = textView.string
            let caret = LineIndex(old).position(of: textView.selectedRange().location)
            let scrollOrigin = scrollView.contentView.bounds.origin
            let full = NSRange(location: 0, length: (old as NSString).length)
            if textView.isEditable, textView.shouldChangeText(in: full, replacementString: text) {
                textView.replaceCharacters(in: full, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
                undoManagers[documentID]?.removeAllActions()
                ruler?.textDidChange()
                applyStyling()
            }
            textView.setSelectedRange(NSRange(location: LineIndex(text).offset(of: caret), length: 0))
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: Text changes

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            lastReplacement = replacementString
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onChange(textView.string)
            ruler?.textDidChange()
            applyStyling()
            endHover()

            let typed = lastReplacement
            lastReplacement = nil
            guard parent.highlightCode, !isApplyingCompletion else { return }

            // Signature help: open on "(" / ",", keep it current while visible.
            if typed == "(" || typed == "," {
                scheduleSignatureHelp(after: .zero)
            } else if signaturePopup.isVisible {
                scheduleSignatureHelp(after: .milliseconds(120))
            }

            if let typed, typed.utf16.count == 1, let unit = typed.utf16.first,
               unit == 0x2E || Identifier.isIdentifier(unit) {
                if unit == 0x2E {  // "." starts a fresh member completion
                    completionItems = []
                    completionPopup.hide()
                    scheduleCompletion(after: .zero)
                } else {
                    refilterCompletions()
                    scheduleCompletion(after: .milliseconds(80))
                }
            } else if typed == "", completionPopup.isVisible {
                refilterCompletions()
                scheduleCompletion(after: .milliseconds(80))
            } else {
                hideCompletions()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.services.caretMoved(textView.selectedRange())
            ruler?.needsDisplay = true
            if signaturePopup.isVisible, let start = signatureLineStart {
                let ns = textView.string as NSString
                let caret = min(textView.selectedRange().location, ns.length)
                if ns.lineRange(for: NSRange(location: caret, length: 0)).location != start { hideSignature() }
            }
        }

        // MARK: Keys

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if completionPopup.isVisible {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    completionPopup.moveSelection(by: -1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    completionPopup.moveSelection(by: 1)
                    return true
                case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                    completionPopup.moveSelection(by: -CompletionPopup.visibleRows)
                    return true
                case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                    completionPopup.moveSelection(by: CompletionPopup.visibleRows)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if let item = completionPopup.selectedItem { accept(item) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    hideCompletions()
                    return true
                case #selector(NSResponder.deleteBackward(_:)):
                    return false  // keep the list open; textDidChange refilters
                default:
                    hideCompletions()
                }
            }

            switch selector {
            case #selector(NSResponder.cancelOperation(_:)) where signaturePopup.isVisible:
                hideSignature()
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                // Esc / ⌥Esc: show completions on demand.
                if parent.highlightCode && textView.isEditable { scheduleCompletion(after: .zero) }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                autoIndentNewline(in: textView)
                return true
            case #selector(NSResponder.insertTab(_:)):
                return insertSoftTab(in: textView)
            case #selector(NSResponder.insertBacktab(_:)):
                shiftLines(in: textView, indent: false)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                return deleteIndent(in: textView)
            default:
                return false
            }
        }

        /// Keep the current line's indentation, indent after `:` / open brackets, dedent after `return` etc.
        private func autoIndentNewline(in textView: NSTextView) {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let before = ns.substring(with: NSRange(location: lineRange.location,
                                                    length: selection.location - lineRange.location))
            textView.insertText("\n" + PythonIndent.indentAfter(line: before), replacementRange: selection)
        }

        /// Tab inserts spaces up to the next 4-column stop; with a multi-line selection it indents the lines.
        private func insertSoftTab(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            if selection.length > 0, ns.substring(with: selection).contains("\n") {
                shiftLines(in: textView, indent: true)
                return true
            }
            let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let column = selection.location - lineStart
            let width = PythonIndent.unit.count - column % PythonIndent.unit.count
            textView.insertText(String(repeating: " ", count: width), replacementRange: selection)
            return true
        }

        /// Backspace inside an all-space indent removes back to the previous 4-column stop.
        private func deleteIndent(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location > 0 else { return false }
            let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            guard !before.isEmpty, before.allSatisfy({ $0 == " " }) else { return false }
            let width = PythonIndent.dedentWidth(column: before.count)
            let range = NSRange(location: selection.location - width, length: width)
            guard textView.shouldChangeText(in: range, replacementString: "") else { return true }
            textView.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            return true
        }

        /// Indents or dedents every line touched by the selection by one level.
        private func shiftLines(in textView: NSTextView, indent: Bool) {
            transformSelectedLines(in: textView) { lines in
                lines.map { line in
                    if line.isEmpty { return line }
                    if indent { return PythonIndent.unit + line }
                    let spaces = line.prefix { $0 == " " }.count
                    return String(line.dropFirst(min(spaces, PythonIndent.unit.count)))
                }
            }
        }

        /// ⌘/: comments out the selected lines with `# `, or uncomments them if all are comments.
        func toggleComment() {
            guard let textView, textView.isEditable else { return }
            transformSelectedLines(in: textView) { lines in
                let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !code.isEmpty else { return lines }
                let allCommented = code.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                if allCommented {
                    return lines.map { line in
                        guard let hash = line.firstIndex(of: "#") else { return line }
                        var rest = line[line.index(after: hash)...]
                        if rest.first == " " { rest = rest.dropFirst() }
                        return String(line[..<hash]) + rest
                    }
                }
                let column = code.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
                return lines.map { line in
                    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                    let i = line.index(line.startIndex, offsetBy: column)
                    return String(line[..<i]) + "# " + line[i...]
                }
            }
        }

        /// Replaces the full lines covered by the selection, as one undoable edit, and reselects them.
        private func transformSelectedLines(in textView: NSTextView, _ transform: ([String]) -> [String]) {
            let ns = textView.string as NSString
            var selection = textView.selectedRange()
            // A selection ending right after a newline doesn't include the next line.
            if selection.length > 0, ns.character(at: NSMaxRange(selection) - 1) == 0x0A { selection.length -= 1 }
            let lineRange = ns.lineRange(for: selection)
            var block = ns.substring(with: lineRange)
            let trailingNewline = block.hasSuffix("\n")
            if trailingNewline { block.removeLast() }
            let newBlock = transform(block.components(separatedBy: "\n")).joined(separator: "\n")
                + (trailingNewline ? "\n" : "")
            guard newBlock != ns.substring(with: lineRange),
                  textView.shouldChangeText(in: lineRange, replacementString: newBlock) else { return }
            textView.replaceCharacters(in: lineRange, with: newBlock)
            textView.didChangeText()
            let length = (newBlock as NSString).length - (trailingNewline ? 1 : 0)
            textView.setSelectedRange(NSRange(location: lineRange.location, length: max(length, 0)))
        }

        // MARK: Completion

        private func scheduleCompletion(after delay: Duration) {
            completionTask?.cancel()
            completionTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let offset = textView.selectedRange().location
                let items = await self.parent.services.completions(offset)
                guard !Task.isCancelled else { return }
                self.completionItems = items
                self.refilterCompletions()
            }
        }

        private func refilterCompletions() {
            guard let textView, let window = textView.window, !completionItems.isEmpty else {
                completionPopup.hide()
                return
            }
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            let start = Identifier.prefixStart(in: ns, before: caret)
            let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
            if let first = prefix.utf16.first, !Identifier.isIdentifierStart(first) {
                completionPopup.hide()  // typing a number
                return
            }
            let matches = completionItems.filter { FuzzyMatch.matches(prefix, $0.filterText) }
            if matches.isEmpty || (matches.count == 1 && matches[0].insertText == prefix) {
                completionPopup.hide()
                return
            }
            endHover()
            let anchor = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            completionPopup.show(matches, below: anchor, in: window)
        }

        private func hideCompletions() {
            completionTask?.cancel()
            completionTask = nil
            completionItems = []
            completionPopup.hide()
        }

        private func accept(_ item: CompletionItem) {
            hideCompletions()
            guard let textView else { return }
            isApplyingCompletion = true
            defer { isApplyingCompletion = false }

            let caret = textView.selectedRange().location
            let start = Identifier.prefixStart(in: textView.string as NSString, before: caret)
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(item.insertText, replacementRange: NSRange(location: start, length: caret - start))
            var newCaret = start + item.insertText.utf16.count

            // Extra edits (e.g. an auto-added import) sit above the caret; apply bottom-up.
            let index = LineIndex(textView.string)
            let extras = item.additionalEdits
                .map { (range: index.range(from: $0.start, to: $0.end), text: $0.newText) }
                .filter { NSMaxRange($0.range) <= start }
                .sorted { $0.range.location > $1.range.location }
            for edit in extras {
                textView.insertText(edit.text, replacementRange: edit.range)
                newCaret += edit.text.utf16.count - edit.range.length
            }
            textView.undoManager?.endUndoGrouping()
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            textView.scrollRangeToVisible(NSRange(location: newCaret, length: 0))
        }

        // MARK: Hover

        func mouseMoved(to index: Int?) {
            guard parent.highlightCode, let textView, !completionPopup.isVisible else { return }
            guard let index, let word = Identifier.wordRange(in: textView.string as NSString, at: index) else {
                endHover()
                return
            }
            if word == hoverWord { return }
            endHover()
            hoverWord = word
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                let markdown = await self.parent.services.hover(index)
                guard !Task.isCancelled, self.hoverWord == word, let markdown else { return }
                self.showHover(markdown, for: word)
            }
        }

        func endHover() {
            hoverTask?.cancel()
            hoverTask = nil
            hoverWord = nil
            hoverPopover?.close()
            hoverPopover = nil
        }

        private func showHover(_ markdown: String, for range: NSRange) {
            guard let textView, let window = textView.window else { return }
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let viewRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
            let host = NSHostingController(rootView: HoverView(markdown: markdown))
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            popover.contentViewController = host
            popover.show(relativeTo: viewRect, of: textView, preferredEdge: .minY)
            hoverPopover = popover
        }

        // MARK: Definition & misc

        func commandClick(at index: Int) {
            dismissPopups()
            guard parent.highlightCode else { return }
            parent.services.definition(index)
        }

        func dismissPopups() {
            endHover()
            hideCompletions()
            hideSignature()
        }

        // MARK: Signature help

        private func scheduleSignatureHelp(after delay: Duration) {
            signatureTask?.cancel()
            signatureTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let caret = textView.selectedRange().location
                let info = await self.parent.services.signatureHelp(caret)
                guard !Task.isCancelled, let window = textView.window else { return }
                guard let info, textView.selectedRange().location == caret else {
                    self.signaturePopup.hide()
                    return
                }
                let ns = textView.string as NSString
                let lineStart = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0)).location
                self.signatureLineStart = lineStart
                // Anchor at the line's first character so the popup doesn't jitter while typing.
                let caretRect = textView.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
                let lineRect = textView.firstRect(forCharacterRange: NSRange(location: lineStart, length: 0), actualRange: nil)
                let anchor = NSRect(x: min(lineRect.minX + 40, caretRect.minX), y: caretRect.minY,
                                    width: 1, height: caretRect.height)
                self.signaturePopup.show(info, above: anchor, in: window)
            }
        }

        private func hideSignature() {
            signatureTask?.cancel()
            signatureTask = nil
            signatureLineStart = nil
            signaturePopup.hide()
        }

        // MARK: Context menu

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard parent.highlightCode else { return menu }
            // Act on the clicked word, not wherever the caret was.
            let index = (view as? CodeTextView)?.characterIndex(atWindowPoint: event.locationInWindow) ?? charIndex
            if view.selectedRange().length == 0 { view.setSelectedRange(NSRange(location: index, length: 0)) }
            let items: [(String, Selector)] = (view.isEditable ? [("Quick Fix…", #selector(menuQuickFix(_:)))] : []) + [
                ("Go to Definition", #selector(menuDefinition(_:))),
                ("Find References", #selector(menuReferences(_:))),
            ] + (view.isEditable ? [("Rename Symbol…", #selector(menuRename(_:)))] : [])
            for (offset, (title, action)) in items.enumerated() {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.insertItem(item, at: offset)
            }
            menu.insertItem(.separator(), at: items.count)
            return menu
        }

        @objc private func menuQuickFix(_ sender: NSMenuItem) { parent.services.quickFix(sender.tag) }
        @objc private func menuDefinition(_ sender: NSMenuItem) { parent.services.definition(sender.tag) }
        @objc private func menuReferences(_ sender: NSMenuItem) { parent.services.references(sender.tag) }
        @objc private func menuRename(_ sender: NSMenuItem) { parent.services.rename(sender.tag) }

        @objc func didScroll(_ notification: Notification) {
            dismissPopups()
            ruler?.needsDisplay = true
        }

        // MARK: Styling

        func applyStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let fullRange = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(EditorTheme.baseAttributes, range: fullRange)
            if parent.highlightCode {
                for token in PythonHighlighter.tokenize(text) {
                    storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: token.range)
                }
            }
            let index = LineIndex(text)
            for diagnostic in parent.diagnostics {
                var range = index.range(from: diagnostic.start, to: diagnostic.end)
                if range.length == 0 { range.length = min(1, storage.length - range.location) }
                guard range.length > 0 else { continue }
                let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemYellow
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: color,
                    .toolTip: diagnostic.message,
                ], range: range)
            }
            storage.endEditing()

            if let line = parent.executionLine, line < index.lineCount {
                let start = index.lineStarts[line]
                let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] : storage.length
                storage.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.22),
                                     range: NSRange(location: start, length: max(end - start, 0)))
            }
            appliedExecutionLine = parent.executionLine
            ruler?.setDiagnostics(parent.diagnostics)
            appliedDiagnostics = parent.diagnostics
            appliedHighlightCode = parent.highlightCode
        }
    }
}

/// NSTextView that reports hover positions and ⌘-clicks.
final class CodeTextView: NSTextView {
    var onMouseMoved: ((Int?) -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onCommandClick: ((Int) -> Void)?
    var onToggleComment: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(characterIndex(atWindowPoint: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        if event.modifierFlags.contains(.command), let index = characterIndex(atWindowPoint: event.locationInWindow) {
            setSelectedRange(NSRange(location: index, length: 0))
            onCommandClick?(index)
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "/", window?.firstResponder === self {
            onToggleComment?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Index of the character under a window point, or nil when the point isn't over text.
    func characterIndex(atWindowPoint windowPoint: NSPoint) -> Int? {
        let length = (string as NSString).length
        guard length > 0, let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let insertion = characterIndexForInsertion(at: convert(windowPoint, from: nil))
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < length {
            let rect = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            if rect.width > 0, rect.insetBy(dx: -0.5, dy: -0.5).contains(screenPoint) { return candidate }
        }
        return nil
    }
}

/// On macOS 14+ a scroll view's ruler overlays the content: the clip view gets a left
/// `contentInsets` equal to the ruler width, so "scrolled to the left edge" means a bounds
/// origin of -inset, not 0. The inset arrives after the text is loaded, which would leave the
/// first characters of every line hidden under the line numbers. Keep the view pinned to the
/// real left edge when the inset changes.
final class EditorScrollView: NSScrollView {
    private var appliedLeftInset: CGFloat = 0

    override func tile() {
        let wasAtLeftEdge = abs(contentView.bounds.minX + appliedLeftInset) < 0.5
        super.tile()
        let inset = contentView.contentInsets.left
        guard abs(inset - appliedLeftInset) > 0.5 else { return }
        appliedLeftInset = inset
        if wasAtLeftEdge {
            contentView.scroll(to: NSPoint(x: -inset, y: contentView.bounds.minY))
            reflectScrolledClipView(contentView)
        }
    }

    func scrollToTopLeft() {
        let insets = contentView.contentInsets
        contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
        reflectScrolledClipView(contentView)
    }
}
