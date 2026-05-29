import Foundation
import CoreServices

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void
    private var debounceTask: DispatchWorkItem?
    private let debounceMs: Int

    init(paths: [String], debounceMs: Int = 300, callback: @escaping () -> Void) {
        self.callback = callback
        self.debounceMs = debounceMs

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let streamCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleFire()
        }

        let cfPaths = paths as CFArray
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            streamCallback,
            &ctx,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            FileHandle.standardError.write(Data("stackd: watching \(paths.joined(separator: ", "))\n".utf8))
        } else {
            FileHandle.standardError.write(Data("stackd: FSEventStream creation failed\n".utf8))
        }
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
