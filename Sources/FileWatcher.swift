import Foundation
import CoreServices

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void
    private var debounceTask: DispatchWorkItem?
    private let debounceMs: Int
    // Folders the daemon is moving itself and applies surgically (stack
    // disable / enable), with when to stop skipping them. Main thread only,
    // like the stream callback.
    private var ignored: [(path: String, until: Date)] = []

    // Only changes to these extensions trigger a reload. Runtime data files
    // (SQLite WALs from sd.sqlite, plists from sd.settings, .pid/.lock/.log
    // from stack-side code) must not cycle the whole host — a stack writing
    // to its own data dir would otherwise tear down every other stack on
    // every commit.
    private static let reloadExtensions: Set<String> = [
        "js", "mjs", "html", "htm", "css", "json", "svg", "wasm"
    ]

    init(paths: [String], debounceMs: Int = 300, callback: @escaping () -> Void) {
        self.callback = callback
        self.debounceMs = debounceMs

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let streamCallback: FSEventStreamCallback = {
            _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>
                .fromOpaque(eventPaths)
                .takeUnretainedValue() as! [String]
            // Reload triggers: (a) a file with a stack-source extension, or
            // (b) a directory create/rename/remove anywhere under a watched
            // root. (b) catches `cp -r examples/foo ~/stackd/stacks/foo` —
            // FSEvents coalesces the inner file events under the new dir
            // path on initial creation, so checking the parent dir event is
            // the only way to notice a new stack folder appeared.
            let dirFlag = UInt32(kFSEventStreamEventFlagItemIsDir)
            for i in 0..<numEvents {
                let path  = paths[i]
                let flags = eventFlags[i]
                if watcher.isIgnored(path) { continue }
                let ext   = (path as NSString).pathExtension.lowercased()
                if FileWatcher.reloadExtensions.contains(ext) {
                    watcher.scheduleFire(); return
                }
                if (flags & dirFlag) != 0 {
                    watcher.scheduleFire(); return
                }
            }
        }

        let cfPaths = paths as CFArray
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            streamCallback,
            &ctx,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            UInt32(kFSEventStreamCreateFlagFileEvents
                 | kFSEventStreamCreateFlagNoDefer
                 | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            log("watching \(paths.joined(separator: ", "))")
        } else {
            log("FSEventStream creation failed")
        }
    }

    /// Skip events at or under `path` for the next `seconds`. Both the path
    /// as given and its resolved form are matched, since FSEvents reports
    /// canonical paths.
    func ignore(_ path: String, for seconds: TimeInterval = 2) {
        let until = Date().addingTimeInterval(seconds)
        ignored.append((path, until))
        // A folder about to be moved IN doesn't exist yet: resolve its parent.
        let ns = path as NSString
        let resolved = Self.resolved(path)
            ?? Self.resolved(ns.deletingLastPathComponent).map { $0 + "/" + ns.lastPathComponent }
        if let resolved = resolved, resolved != path { ignored.append((resolved, until)) }
    }

    private static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private func isIgnored(_ path: String) -> Bool {
        let now = Date()
        ignored.removeAll { $0.until < now }
        return ignored.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    private func scheduleFire() {
        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.callback() }
        debounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(debounceMs), execute: task)
    }

    func stop() {
        debounceTask?.cancel()
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
