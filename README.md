# PyIDE

A native macOS IDE for Python, written in Swift (SwiftUI + AppKit).
Sibling project of [golang-ide](https://github.com/lai3d/golang-ide), sharing the same LSP-client architecture.

> Early scaffold — usable for editing small Python projects, not yet a daily driver.

## Features

- Project sidebar (open any folder; hides `__pycache__`, `.venv`, caches, `*.egg-info`)
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
- **Format on save** with ruff (or black), on by default and toggled in the *Python* menu; *Format Document* with ⇧⌥F. Formatting is a single undoable edit that keeps the caret's line/column; formatter errors (e.g. a syntax error) show in the status bar and the file is saved unformatted.
- **Interpreter detection**: uses the project's `.venv` / `venv` / `env` if present, else `$VIRTUAL_ENV`, else `python3`; pick another from the status bar or *Python → Choose Interpreter…*. The interpreter is passed to pyright, so imports from your venv resolve.
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
swift test                         # unit tests + language-server end-to-end tests
./scripts/bundle.sh                # build build/PyIDE.app (release, ad-hoc signed)
open build/PyIDE.app
```

You can also open `Package.swift` in Xcode.

## Layout

| Path | What |
|---|---|
| `Sources/PyIDECore` | UI-independent core: JSON-RPC/LSP client, message framing, Python highlighter & indent rules, interpreter / language-server discovery, LSP position math, file tree |
| `Sources/PyIDE` | SwiftUI app: workspace state, editor view, sidebar, panels |
| `Tests/PyIDECoreTests` | swift-testing tests |
| `Examples/hello` | Small Python project for trying things out |

## Roadmap

- Code actions / quick fixes, document symbols outline
- Integrated REPL panel; Jupyter notebook viewing
- tree-sitter-python for incremental highlighting
- Debugging via debugpy's DAP (breakpoints, stepping, variables)

## License

MIT — see [LICENSE](LICENSE).
