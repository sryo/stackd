import Foundation

/// Tests for `Log` — timestamped line format and in-place size trimming of
/// the launchd-owned log file.
func registerLogTests() {
    func tempAppendFD() -> (Int32, String) {
        let path = NSTemporaryDirectory() + "stackd-logtest-\(UUID().uuidString).log"
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return (fd, path)
    }
    func contents(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    test("log line: local timestamp with millis, then the stackd prefix") {
        var tv = timeval(tv_sec: 1_790_000_000, tv_usec: 42_000)
        let line = Log.line("hello", at: tv)
        var t = time_t(tv.tv_sec)
        var tmv = tm()
        localtime_r(&t, &tmv)
        let expected = String(format: "%04d-%02d-%02d %02d:%02d:%02d.042 stackd: hello\n",
                              tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                              tmv.tm_hour, tmv.tm_min, tmv.tm_sec)
        try expectEqual(line, expected)
        tv.tv_usec = 999_999
        try expect(Log.line("x", at: tv).contains(".999 stackd: x\n"), "millis truncate, never round up to 1000")
    }

    test("trim: under the cap leaves the file untouched") {
        let (fd, path) = tempAppendFD(); defer { close(fd); unlink(path) }
        let body = "a\nb\nc\n"
        _ = body.withCString { write(fd, $0, strlen($0)) }
        try expect(!Log.trim(fd: fd, maxBytes: 100, keepBytes: 50))
        try expectEqual(contents(path), body)
    }

    test("trim: over the cap keeps the newest whole lines within keepBytes") {
        let (fd, path) = tempAppendFD(); defer { close(fd); unlink(path) }
        let lines = (0..<200).map { "line \($0)\n" }.joined()
        _ = lines.withCString { write(fd, $0, strlen($0)) }
        try expect(Log.trim(fd: fd, maxBytes: 1000, keepBytes: 300))
        let kept = contents(path)
        try expect(kept.utf8.count <= 300, "kept \(kept.utf8.count) bytes")
        try expect(kept.hasPrefix("line "), "starts on a line boundary: \(kept.prefix(12))")
        try expect(kept.hasSuffix("line 199\n"))
        try expect(lines.hasSuffix(kept), "kept bytes are the file's tail")
    }

    test("trim: later appends land right after the kept tail (no hole)") {
        let (fd, path) = tempAppendFD(); defer { close(fd); unlink(path) }
        let lines = (0..<200).map { "line \($0)\n" }.joined()
        _ = lines.withCString { write(fd, $0, strlen($0)) }
        _ = Log.trim(fd: fd, maxBytes: 1000, keepBytes: 300)
        _ = "after\n".withCString { write(fd, $0, strlen($0)) }
        let kept = contents(path)
        try expect(kept.hasSuffix("line 199\nafter\n"))
        try expect(!kept.contains("\0"))
    }

    test("trim: a non-regular fd (pipe, tty) is never touched") {
        var fds: [Int32] = [0, 0]
        try expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        try expect(!Log.trim(fd: fds[1], maxBytes: 0, keepBytes: 0))
    }
}
