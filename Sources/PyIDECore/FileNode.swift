import Foundation

/// A node in the project file tree.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// `nil` for files, so outline views show no disclosure triangle.
    public var children: [FileNode]?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public static let ignoredNames: Set<String> = [
        ".git", ".build", ".idea", ".vscode", "node_modules", "__pycache__", ".venv", "venv",
        ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox", ".nox", ".eggs", "build", "dist",
    ]

    public init(url: URL, isDirectory: Bool, children: [FileNode]?) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }

    public static func loadTree(at root: URL, maxDepth: Int = 12) -> [FileNode] {
        loadChildren(of: root, depth: 0, maxDepth: maxDepth)
    }

    private static func loadChildren(of directory: URL, depth: Int, maxDepth: Int) -> [FileNode] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        return items
            .filter { !ignoredNames.contains($0.lastPathComponent) && !$0.lastPathComponent.hasSuffix(".egg-info") }
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let children = isDir ? (depth < maxDepth ? loadChildren(of: url, depth: depth + 1, maxDepth: maxDepth) : []) : nil
                return FileNode(url: url, isDirectory: isDir, children: children)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}
