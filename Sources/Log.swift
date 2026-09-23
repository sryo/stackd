import Foundation

func log(_ s: String) {
    Log.write(s)
}

/// The daemon's log. Every line is stamped with local wall-clock time, and
/// when stderr is a regular file (launchd's StandardErrorPath) it is capped
/// in place: past `maxBytes` the file is cut down to its newest
/// `keepBytes`. Trimming works on the open fd because launchd opens the log
/// O_APPEND — after ftruncate every writer's next append lands at the new end.
enum Log {
    static let maxBytes = 10 << 20
    static let keepBytes = 5 << 20
    /// How much the daemon writes between size checks — keeps fstat off the
    /// per-line path.
    private static let checkEvery = 1 << 20

    private static let lock = NSLock()
    private static var trimming = false
    private static var bytesSinceCheck = 0

    /// Daemon-mode setup: point stdout at stderr's open file description when
    /// launchd gave both the same file (so a trim can't leave stdout's offset
    /// past the new end), trim once, and enable periodic trimming.
    static func startDaemonLog() {
        var out = stat(), err = stat()
        if fstat(STDOUT_FILENO, &out) == 0, fstat(STDERR_FILENO, &err) == 0,
           out.st_dev == err.st_dev, out.st_ino == err.st_ino {
            dup2(STDERR_FILENO, STDOUT_FILENO)
        }
        lock.lock(); defer { lock.unlock() }
        trimming = true
        _ = trim(fd: STDERR_FILENO, maxBytes: maxBytes, keepBytes: keepBytes)
    }

    static func write(_ s: String) {
        var tv = timeval()
        gettimeofday(&tv, nil)
        let bytes = Array(line(s, at: tv).utf8)
        lock.lock(); defer { lock.unlock() }
        bytes.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(STDERR_FILENO, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
        guard trimming else { return }
        bytesSinceCheck += bytes.count
        if bytesSinceCheck >= checkEvery {
            bytesSinceCheck = 0
            _ = trim(fd: STDERR_FILENO, maxBytes: maxBytes, keepBytes: keepBytes)
        }
    }

    /// `YYYY-MM-DD HH:MM:SS.mmm stackd: <s>\n`, local time.
    static func line(_ s: String, at tv: timeval) -> String {
        var t = time_t(tv.tv_sec)
        var tmv = tm()
        localtime_r(&t, &tmv)
        var buf = [CChar](repeating: 0, count: 32)
        strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tmv)
        let millis = Int(tv.tv_usec) / 1000
        return String(cString: buf) + String(format: ".%03d stackd: ", millis) + s + "\n"
    }

    /// Cuts a regular file larger than `maxBytes` down to its newest whole
    /// lines fitting in `keepBytes`. Returns whether it trimmed. Pipes and
    /// ttys are left alone.
    @discardableResult
    static func trim(fd: Int32, maxBytes: Int, keepBytes: Int) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              Int(st.st_size) > maxBytes else { return false }
        let size = Int(st.st_size)
        let start = max(0, size - keepBytes)
        // launchd opens the log write-only, so the tail is read through a
        // second, read-only descriptor for the same file.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { return false }
        let rfd = open(path, O_RDONLY)
        guard rfd >= 0 else { return false }
        defer { close(rfd) }
        var tail = [UInt8](repeating: 0, count: size - start)
        let got = tail.withUnsafeMutableBytes { pread(rfd, $0.baseAddress, $0.count, off_t(start)) }
        guard got >= 0 else { return false }
        tail.removeSubrange(got...)
        if start > 0, let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail.removeSubrange(...nl)
        }
        guard ftruncate(fd, 0) == 0 else { return false }
        tail.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
        return true
    }
}
