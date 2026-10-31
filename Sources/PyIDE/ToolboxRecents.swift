import Foundation

/// Shares recently opened projects with IDE Toolbox (https://github.com/lai3d/ide-toolbox).
///
/// Writes `~/Library/Application Support/IDEToolbox/recents/<bundle-id>.json`, newest first:
/// `{ "projects": [ { "path": "/Users/me/code/app", "openedAt": "2026-10-31T13:00:00Z" } ] }`
enum ToolboxRecents {
    private struct File: Codable {
        struct Project: Codable {
            var path: String
            var openedAt: Date
        }
        var projects: [Project]
    }

    static func record(_ folder: URL) {
        // Only the bundled .app shares recents, not `swift run` or test runs.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IDEToolbox/recents")
        let url = dir.appendingPathComponent("\(bundleID).json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var file = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(File.self, from: $0) }
            ?? File(projects: [])
        file.projects.removeAll { $0.path == folder.path }
        file.projects.insert(.init(path: folder.path, openedAt: Date()), at: 0)
        file.projects = Array(file.projects.prefix(20))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? encoder.encode(file).write(to: url, options: .atomic)
    }
}
