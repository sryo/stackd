import Foundation

// One-shot subprocess execution: launch, wait, capture stdout+stderr+exit.
// Long-running spawn() with line-streaming deferred to a later iteration
// when something actually needs it (Muse's AI backends, Sssssssscroll's
// Python detector — neither is in the current port queue).

enum Proc {
    static func exec(
        cmd: String,
        args: [String],
        input: String? = nil,
        timeoutSeconds: Double? = nil,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let task = Process()
        task.launchPath = cmd
        task.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = errPipe

        if let inp = input, !inp.isEmpty {
            let inPipe = Pipe()
            task.standardInput = inPipe
            DispatchQueue.global(qos: .utility).async {
                if let data = inp.data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()
            }
        }

        do {
            try task.run()
        } catch {
            completion([
                "code":   -1,
                "stdout": "",
                "stderr": "stackd: failed to launch \(cmd): \(error.localizedDescription)"
            ])
            return
        }

        // Drain pipes on a background queue; main-thread blocking is bad form.
        DispatchQueue.global(qos: .utility).async {
            let stdoutData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            task.waitUntilExit()
            DispatchQueue.main.async {
                completion([
                    "code":   Int(task.terminationStatus),
                    "stdout": String(data: stdoutData, encoding: .utf8) ?? "",
                    "stderr": String(data: stderrData, encoding: .utf8) ?? ""
                ])
            }
        }

        if let timeout = timeoutSeconds {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if task.isRunning { task.terminate() }
            }
        }
    }
}
