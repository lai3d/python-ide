# PyIDE

A native macOS IDE for Python, written in Swift (SwiftUI + AppKit).
Sibling project of [golang-ide](https://github.com/lai3d/golang-ide), sharing the same LSP-client architecture.

> Early scaffold — usable for editing small Python projects, not yet a daily driver.

## Features

- Project sidebar (open any folder; hides `__pycache__`, `.venv`, caches, `*.egg-info`) that updates live as files are created or deleted, plus an **Outline** mode listing the current file's classes, functions and variables (click to jump)
- **Tabs** for multiple open files: each keeps its own caret, scroll position and undo history; ⌘W closes (asks to save unsaved changes), ⇧⌘] / ⇧⌘[ switch, ⌥⌘S saves all; right-click for Close Others / Close All / Reveal in Finder
- **Line-number gutter** with the caret line highlighted and red/yellow dots on lines with errors/warnings; click a number to select the line
- NSTextView editor with Python syntax highlighting (keywords, soft keywords `match`/`case`, decorators, f/r/b and triple-quoted strings), find bar, undo
- Python editing: 4-space soft tabs, auto-indent after `:` and open brackets, dedent after `return`/`pass`/`break`/`continue`/`raise`, smart backspace through indents, ⇥/⇧⇥ to indent/dedent selected lines, ⌘/ to toggle `#` comments
- **pyright** (or basedpyright / pylsp / jedi-language-server) over LSP:
  - live diagnostics as you type, shown as underlines and in the Problems panel (click to jump)
  - **completion** as you type identifiers or `.` (or press Esc): ↑/↓ to choose, ↩/⇥ to accept; auto-import edits applied
  - **hover** for signatures and docstrings
  - **go to definition**: ⌘-click or ⌃⌘J, back with ⌃⌘← (stdlib stubs / site-packages open read-only)
  - **signature help** while typing a call: pops up on `(` / `,` with the current parameter highlighted; Esc dismisses
  - **find references** (⌥⌘R or right-click): results in a References panel, click to jump
  - **rename symbol** (⌃⌘E or right-click) across the project; changed files open as unsaved tabs so nothing is written until you save
- **ruff language server** (`ruff server`, started automatically when ruff is installed) alongside pyright: lint diagnostics with rule codes in the Problems panel (problems pyright also reports, like undefined names, are shown once), and **per-problem quick fixes** — ⌥↩ (or right-click → *Quick Fix…*) on a line lists fixes such as "Remove unused import", "Disable for this line", then *Fix all* / *Organize imports*
- **Quick fixes with ruff**: *Fix All* (⇧⌥⌘F) applies every safe autofix from your ruff config (unused imports, pyupgrade, …) and *Organize Imports* (⇧⌥O) sorts imports — both as a single undoable edit
- **Format on save** with ruff (or black), on by default and toggled in the *Python* menu; *Format Document* with ⇧⌥F. Formatting is a single undoable edit that keeps the caret's line/column; formatter errors (e.g. a syntax error) show in the status bar and the file is saved unformatted.
- **Interpreter detection**: uses the project's `.venv` / `venv` / `env` if present, else `$VIRTUAL_ENV`, else `python3`; pick another from the status bar or *Python → Choose Interpreter…*. The interpreter is passed to pyright, so imports from your venv resolve.
- **REPL panel** (⌃⌘P): an interactive `python -i` in the project folder with the project interpreter; ↑/↓ history, interrupt, restart, clear. **Send Selection to REPL** (⌃↩) sends the selected code, or the caret's line, with indentation and block endings fixed up
- **Debugger** (debugpy over DAP): click a line number (or ⌘\\) to set a breakpoint; **Debug File** (⇧⌘D or the ladybug button) pauses on breakpoints and uncaught exceptions with the line highlighted; Continue ⌃⌘Y, Step Over F6, Into F7, Out F8, Stop ⌘.; the Debug panel shows the call stack (click to switch frames), expandable variables, and a console that evaluates expressions in the selected frame. If debugpy isn't in your interpreter, PyIDE offers to install it into `~/Library/Application Support/PyIDE/debugpy` (your environment is untouched). Breakpoints move with the code as you insert or delete lines; right-click a line number for **conditional breakpoints** (purple) or **logpoints** (teal: print a message like `i = {i}` without pausing) and **hit counts** (pause only on the 3rd hit, `>= 3`, `% 2`). Double-click a variable's value in the Debug panel to change it while paused. **Watch expressions** in the Debug panel are re-evaluated in the selected frame at every pause. The debugged program runs with its stdin connected to the Debug console: while it runs, what you type goes to `input()`; while paused, it's evaluated in the selected frame.
- **Jupyter notebooks** (`.ipynb`): edit and run cells. Code cells are highlighted, get **completion** from pyright (it sees all code cells together, so earlier imports and definitions complete), and run in a per-notebook kernel using the project interpreter (no Jupyter install needed): ⇧↩ runs and moves on, ⌘↩ runs in place; the last expression is displayed, matplotlib figures become images, `input()` prompts you, Interrupt / Restart / Run All / Clear Outputs in the notebook toolbar. Markdown cells render (double-click to edit); add, move, delete and change cells from the cell toolbar. Saves standard nbformat JSON (same formatting as Jupyter); tick *Show JSON* for the raw file
- Run the current file (⌘R), test with pytest or `unittest discover` (⌘U), check with `ruff check` / pyright / `compileall` (⌘B), stop (⌘. sends SIGINT)
- Output panel with a **stdin field** while a program runs, so `input()` works (plus an EOF button)

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)
- Python 3, plus a language server — pyright recommended:
  `npm install -g pyright` (or `uv tool install basedpyright`, `pip install python-lsp-server`)
- Optional: `ruff` for formatting and ⌘B (`uv tool install ruff`), `pytest` for ⌘U

PyIDE looks for tools in the interpreter's `bin` directory first, then `PATH`, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, so it works when launched from Finder too.

## Build & run

```sh
swift run PyIDE Examples/hello     # run in debug, opening the example project
swift test                         # core unit tests, language-server/debugger/kernel end-to-end tests,
                                   # and app-level tests that drive the Workspace directly
./scripts/bundle.sh                # build build/PyIDE.app (release, ad-hoc signed)
open build/PyIDE.app
```

You can also open `Package.swift` in Xcode.

## Layout

| Path | What |
|---|---|
| `Sources/PyIDECore` | UI-independent core: JSON-RPC/LSP client, message framing, Python highlighter & indent rules, interpreter / language-server discovery, LSP position math, file tree |
| `Sources/PyIDE` | SwiftUI app: workspace state, editor view, sidebar, panels |
| `Tests/PyIDECoreTests` | swift-testing tests for the core |
| `Tests/PyIDETests` | App-level tests that drive `Workspace` (notebook runs, format on save, quick fixes) |
| `Examples/hello` | Small Python project for trying things out |

## Roadmap

- Jupyter: rich outputs (HTML tables, LaTeX), hover/diagnostics inside cells, real Jupyter kernels
- tree-sitter-python for incremental highlighting
- Debugger: attach to a running process, multi-thread stepping UI

## License

MIT — see [LICENSE](LICENSE).
