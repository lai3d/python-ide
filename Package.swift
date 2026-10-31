// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PyIDE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PyIDE", targets: ["PyIDE"]),
        .library(name: "PyIDECore", targets: ["PyIDECore"]),
    ],
    targets: [
        // UI-independent pieces: LSP client, Go highlighter, text/position math, file tree.
        .target(name: "PyIDECore"),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "PyIDE", dependencies: ["PyIDECore"]),
        .testTarget(name: "PyIDECoreTests", dependencies: ["PyIDECore"]),
    ]
)
