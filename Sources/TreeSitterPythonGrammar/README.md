Vendored from https://github.com/tree-sitter/tree-sitter-python v0.25.0
(commit 293fdc02038ee2bf0e2e206711b69c90ac0d413f), MIT license (see LICENSE).

Vendored rather than used as a package: its manifest only compiles `src/scanner.c` when
`FileManager.fileExists("src/scanner.c")` is true relative to the *current directory*, which
isn't the package directory under SwiftPM's build system, so linking fails.

To update: copy `src/parser.c`, `src/scanner.c` and `src/tree_sitter/*.h` from a release.
