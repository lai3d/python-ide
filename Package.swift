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
        // UI-independent pieces: LSP/DAP clients, Python highlighter, kernels, text/position math, file tree.
        .target(name: "PyIDECore"),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "PyIDE", dependencies: ["PyIDECore"]),
        .testTarget(name: "PyIDECoreTests", dependencies: ["PyIDECore"]),
        // Drives the app's Workspace directly (no UI automation needed).
        .testTarget(name: "PyIDETests", dependencies: ["PyIDE", "PyIDECore"]),
    ]
)
