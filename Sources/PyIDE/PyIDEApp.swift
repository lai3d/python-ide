import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a dead language server's stdin must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    weak var workspace: Workspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        return workspace.confirmDiscardOrSave(workspace.documents) ? .terminateNow : .terminateCancel
    }
}

@main
struct PyIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup("PyIDE") {
            ContentView()
                .environment(workspace)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.workspace = workspace }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { workspace.closeCurrentTab() }
                    .keyboardShortcut("w")
                    .disabled(workspace.currentFile == nil)
                Button("Save") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(workspace.currentFile == nil)
                Button("Save All") { workspace.saveAll() }
                    .keyboardShortcut("s", modifiers: [.option, .command])
                    .disabled(!workspace.hasUnsavedChanges)
            }
            CommandMenu("Navigate") {
                Button("Jump to Definition") {
                    Task { await workspace.jumpToDefinition(at: workspace.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.control, .command])
                .disabled(!workspace.isPythonFile)
                Button("Find References") {
                    Task { await workspace.findReferences(at: workspace.caretOffset) }
                }
                .keyboardShortcut("r", modifiers: [.option, .command])
                .disabled(!workspace.isPythonFile)
                Button("Rename Symbol…") {
                    Task { await workspace.renameSymbol(at: workspace.caretOffset) }
                }
                .keyboardShortcut("e", modifiers: [.control, .command])
                .disabled(!workspace.isPythonFile || workspace.isReadOnly)
                Divider()
                Button("Go Back") { workspace.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                    .disabled(!workspace.canGoBack)
                Divider()
                Button("Next Tab") { workspace.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.shift, .command])
                    .disabled(workspace.documents.count < 2)
                Button("Previous Tab") { workspace.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.shift, .command])
                    .disabled(workspace.documents.count < 2)
            }
            CommandMenu("Python") {
                Button("Run File") { workspace.run(.runFile) }
                    .keyboardShortcut("r")
                Button("Check") { workspace.run(.check) }
                    .keyboardShortcut("b")
                Button("Test") { workspace.run(.test) }
                    .keyboardShortcut("u")
                Divider()
                Button("Stop") { workspace.stopRun() }
                    .keyboardShortcut(".")
                Divider()
                Button("Open REPL") {
                    workspace.bottomTab = .repl
                    workspace.startREPL()
                }
                .keyboardShortcut("p", modifiers: [.control, .command])
                .disabled(workspace.rootURL == nil)
                Button("Send Selection to REPL") { workspace.sendSelectionToREPL() }
                    .keyboardShortcut(.return, modifiers: [.control])
                    .disabled(!workspace.isPythonFile)
                Button("Restart REPL") { workspace.restartREPL() }
                    .disabled(workspace.rootURL == nil)
                Divider()
                Button("Format Document") { workspace.formatDocument() }
                    .keyboardShortcut("f", modifiers: [.shift, .option])
                    .disabled(!workspace.isPythonFile || workspace.isReadOnly)
                Toggle("Format on Save", isOn: Bindable(workspace).formatOnSave)
                Divider()
                Button("Choose Interpreter…") { workspace.presentInterpreterPanel() }
                    .disabled(workspace.rootURL == nil)
                Button("Restart Language Server") { Task { await workspace.restartLanguageServer() } }
            }
        }
    }
}
