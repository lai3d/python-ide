import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and calls `onChange` (on the main queue, debounced)
/// when files are created, deleted or renamed. Changes inside ignored folders are skipped.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let ignoredComponents: Set<String>
    private var pending: DispatchWorkItem?

    init(url: URL, ignoredComponents: Set<String>, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.ignoredComponents = ignoredComponents
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                    | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs)
            for i in 0..<min(count, paths.count) where flags[i] & structural != 0 {
                if !watcher.isIgnored(paths[i]) {
                    watcher.scheduleChange()
                    return
                }
            }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit { stop() }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func isIgnored(_ path: String) -> Bool {
        path.split(separator: "/").contains { ignoredComponents.contains(String($0)) || $0.hasSuffix(".egg-info") }
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
