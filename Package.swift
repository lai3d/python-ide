// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PyIDE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PyIDE", targets: ["PyIDE"]),
        .library(name: "PyIDECore", targets: ["PyIDECore"]),
    ],
    dependencies: [
        // Syntax highlighting: tree-sitter (the Python grammar is vendored in TreeSitterPythonGrammar).
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
    ],
    targets: [
        // UI-independent pieces: LSP/DAP clients, Python highlighter, kernels, text/position math, file tree.
        .target(name: "PyIDECore", dependencies: [
            .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            "TreeSitterPythonGrammar",
        ]),
        // tree-sitter-python's generated parser (vendored; see its README).
        .target(name: "TreeSitterPythonGrammar", exclude: ["LICENSE", "README.md"],
                cSettings: [.headerSearchPath("src")]),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "PyIDE", dependencies: ["PyIDECore"]),
        .testTarget(name: "PyIDECoreTests", dependencies: ["PyIDECore"]),
        // Drives the app's Workspace directly (no UI automation needed).
        .testTarget(name: "PyIDETests", dependencies: ["PyIDE", "PyIDECore"]),
    ]
)
