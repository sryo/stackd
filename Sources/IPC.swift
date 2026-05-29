import Foundation
import Darwin

enum IPC {
    static let socketDir: String = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/Library/Application Support/stackd"
    }()
    static var socketPath: String { socketDir + "/daemon.sock" }
    static var pidPath: String { socketDir + "/daemon.pid" }
}

private func makeUnixAddr(path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cstr = path.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let actualLen = min(cstr.count - 1, maxLen - 1)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
            cstr.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, actualLen)
                dst[actualLen] = 0
            }
        }
    }
    return addr
}

final class IPCServer {
    private var listenFd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.stackd.ipc.accept", qos: .utility)
    private let workQueue = DispatchQueue(label: "com.stackd.ipc.work", qos: .utility, attributes: .concurrent)
    private var running = false

    var dispatcher: ((_ argv: [String]) -> String)?

    func start() throws {
        try? FileManager.default.createDirectory(atPath: IPC.socketDir, withIntermediateDirectories: true)

        if let pidStr = try? String(contentsOfFile: IPC.pidPath, encoding: .utf8),
           let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            throw NSError(domain: "stackd", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "daemon already running (pid \(pid))"
            ])
        }
        try? String(getpid()).write(toFile: IPC.pidPath, atomically: true, encoding: .utf8)

        unlink(IPC.socketPath)

        listenFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw NSError(domain: "stackd", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "socket(): \(String(cString: strerror(errno)))"
            ])
        }

        var addr = makeUnixAddr(path: IPC.socketPath)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFd, $0, size) }
        }
        guard bindResult == 0 else {
            let err = errno; close(listenFd); listenFd = -1
            throw NSError(domain: "stackd", code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: "bind(\(IPC.socketPath)): \(String(cString: strerror(err)))"
            ])
        }
        chmod(IPC.socketPath, 0o600)

        guard Darwin.listen(listenFd, 16) == 0 else {
            let err = errno; close(listenFd); listenFd = -1
            throw NSError(domain: "stackd", code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: "listen(): \(String(cString: strerror(err)))"
            ])
        }

        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        FileHandle.standardError.write(Data("stackd: ipc listening on \(IPC.socketPath)\n".utf8))
    }

    private func acceptLoop() {
        while running {
            let fd = accept(listenFd, nil, nil)
            if fd < 0 {
                if !running { return }
                continue
            }
            workQueue.async { [weak self] in self?.handle(client: fd) }
        }
    }

    private func handle(client fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }
        let payload = String(data: data, encoding: .utf8) ?? ""
        let argv = payload
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }

        let sem = DispatchSemaphore(value: 0)
        var response = "error: no dispatcher\n"
        DispatchQueue.main.async { [weak self] in
            response = self?.dispatcher?(argv) ?? "error: no dispatcher\n"
            sem.signal()
        }
        sem.wait()

        response.withCString { ptr in _ = write(fd, ptr, strlen(ptr)) }
    }

    func stop() {
        running = false
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
        unlink(IPC.socketPath)
        unlink(IPC.pidPath)
    }
}

enum IPCClient {
    static func send(argv: [String]) -> (status: Int32, response: String) {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (1, "socket() failed\n") }
        defer { close(fd) }

        var addr = makeUnixAddr(path: IPC.socketPath)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard r == 0 else {
            return (1, "stackd: daemon not running (\(IPC.socketPath): \(String(cString: strerror(errno))))\n")
        }

        // NB: payload contains NUL separators, so strlen would truncate. Write the raw bytes.
        let payload = Data(argv.joined(separator: "\0").utf8)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }
        return (0, String(data: data, encoding: .utf8) ?? "")
    }
}
