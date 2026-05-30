import Foundation
import CoreServices

// Filesystem as a data source: read/stat/list (imperative) + watch (push).
// FileWatcher.swift is internal-only (drives the daemon's auto-reload);
// this file exposes the same FSEventStream machinery to stacks per-watch.

enum FS {
    static func read(path: String) -> String? {
        let p = expand(path)
        return try? String(contentsOfFile: p, encoding: .utf8)
    }

    static func stat(path: String) -> [String: Any]? {
        let p = expand(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { return nil }
        var out: [String: Any] = [
            "path":   p,
            "size":   (attrs[.size] as? Int) ?? 0,
            "isDir":  (attrs[.type] as? FileAttributeType) == .typeDirectory
        ]
        if let date = attrs[.modificationDate] as? Date {
            out["mtime"] = date.timeIntervalSince1970
        }
        return out
    }

    static func list(dir: String, includeHidden: Bool = false) -> [String]? {
        let p = expand(dir)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: p) else { return nil }
        return includeHidden ? items : items.filter { !$0.hasPrefix(".") }
    }

    /// Expand ~ and ~user prefixes. Other paths pass through.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// One FSWatch per active sd.fs.watch subscription. Lifetime owned by Bridge
/// (held in a [watchId: FSWatch] map). Deinit tears the FSEventStream down.
final class FSWatch {
    private var stream: FSEventStreamRef?
    private let callback: ([(path: String, flags: FSEventStreamEventFlags)]) -> Void

    init?(paths: [String], callback: @escaping ([(path: String, flags: FSEventStreamEventFlags)]) -> Void) {
        self.callback = callback
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, numEvents, evPaths, evFlags, _ in
            guard let info = info else { return }
            let watch = Unmanaged<FSWatch>.fromOpaque(info).takeUnretainedValue()
            let pathsAny = unsafeBitCast(evPaths, to: NSArray.self)
            let paths = (pathsAny as? [String]) ?? []
            let flagsBuf = UnsafeBufferPointer(start: evFlags, count: numEvents)
            var events: [(path: String, flags: FSEventStreamEventFlags)] = []
            for i in 0..<min(paths.count, flagsBuf.count) {
                events.append((path: paths[i], flags: flagsBuf[i]))
            }
            watch.callback(events)
        }
        let cfPaths = paths.map { FS.expand($0) } as CFArray
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &ctx,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }
        self.stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    deinit { stop() }

    /// Decode the FSEventStream flags into a stable human-readable kind string.
    /// Multiple bits can be set; we report the most-meaningful one.
    static func kindFor(flags: FSEventStreamEventFlags) -> String {
        let f = Int(flags)
        if f & kFSEventStreamEventFlagItemRemoved   != 0 { return "removed"   }
        if f & kFSEventStreamEventFlagItemCreated   != 0 { return "created"   }
        if f & kFSEventStreamEventFlagItemRenamed   != 0 { return "renamed"   }
        if f & kFSEventStreamEventFlagItemModified  != 0 { return "modified"  }
        if f & kFSEventStreamEventFlagItemInodeMetaMod != 0 { return "meta"   }
        if f & kFSEventStreamEventFlagItemXattrMod  != 0 { return "xattr"     }
        return "changed"
    }
}
