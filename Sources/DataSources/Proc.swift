import Foundation
import OSAKit
import Carbon

// One-shot subprocess execution: launch, wait, capture stdout+stderr+exit.
// Streamed counterpart (Proc.stream) below — progressive chunks via a
// per-pipe readabilityHandler instead of buffer-to-completion.

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

    // Streaming counterpart of Proc.exec. The on-callback fires once per
    // chunk with { stream: "stdout"|"stderr", chunk: <utf8 string> } as the
    // child writes, and once at exit with { stream: "exit", code, signal? }.
    // Buffered payloads are NOT re-sent on exit — callers that need a final
    // joined buffer accumulate the chunks themselves.
    //
    // Returns a ProcStreamHandle whose cancel() sends SIGTERM. The "exit"
    // event still fires after cancel; signal carries the terminating signal
    // when the child died from one (terminationReason == .uncaughtSignal).
    static func stream(
        cmd: String,
        args: [String],
        env: [String: String]? = nil,
        cwd: String? = nil,
        onEvent: @escaping ([String: Any]) -> Void
    ) -> ProcStreamHandle? {
        let task = Process()
        task.launchPath = cmd
        task.arguments  = args
        if let env = env { task.environment = env }
        if let cwd = cwd { task.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = errPipe

        // readabilityHandler fires on the global IO queue. Each non-empty
        // read becomes one "stdout"/"stderr" event; an empty read means the
        // child closed that pipe — clear the handler so we don't spin.
        let drain: (String, FileHandle) -> Void = { stream, handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                onEvent(["stream": stream, "chunk": chunk])
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { drain("stdout", $0) }
        errPipe.fileHandleForReading.readabilityHandler = { drain("stderr", $0) }

        task.terminationHandler = { proc in
            // Flush whatever was buffered between the last readability tick
            // and termination — availableData on a closed pipe returns the
            // remaining bytes without blocking. Then clear handlers so the
            // empty-data callback (if any) doesn't fire a stray event.
            for (label, pipe) in [("stdout", outPipe), ("stderr", errPipe)] {
                let leftover = pipe.fileHandleForReading.availableData
                pipe.fileHandleForReading.readabilityHandler = nil
                if !leftover.isEmpty {
                    let chunk = String(data: leftover, encoding: .utf8) ?? ""
                    DispatchQueue.main.async {
                        onEvent(["stream": label, "chunk": chunk])
                    }
                }
            }
            var payload: [String: Any] = [
                "stream": "exit",
                "code":   Int(proc.terminationStatus)
            ]
            if proc.terminationReason == .uncaughtSignal {
                // terminationStatus on signal death is the signal number.
                payload["signal"] = Int(proc.terminationStatus)
            }
            DispatchQueue.main.async {
                onEvent(payload)
            }
        }

        do {
            try task.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                onEvent([
                    "stream": "stderr",
                    "chunk":  "stackd: failed to launch \(cmd): \(error.localizedDescription)"
                ])
                onEvent(["stream": "exit", "code": -1])
            }
            return nil
        }

        return ProcStreamHandle(task: task)
    }
}

// Handle returned by Proc.stream. cancel() sends SIGTERM; the wrapped
// process keeps a strong ref so the terminationHandler still fires.
final class ProcStreamHandle {
    private let task: Process
    private var cancelled = false
    private let lock = NSLock()

    init(task: Process) { self.task = task }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return }
        cancelled = true
        if task.isRunning { task.terminate() }
    }
}

// In-process AppleScript / JXA runner. OSAKit picks the language at runtime
// (NSAppleScript is AppleScript-only, OSAScript handles both). Faster than
// spawning /usr/bin/osascript per call since the script compiles + executes
// in the daemon's address space — relevant for "every keystroke" callers.
//
// Limitation: executeAndReturnError is synchronous with no built-in timeout.
// v1 runs to completion; a misbehaving script that hangs for >timeout
// blocks the dispatch hop it's scheduled on (the Bridge schedules onto main).
// Subprocess fallback for hard-timeouts is a future addition — until then,
// callers that need a guaranteed bound on wall-time should keep using
// sd.proc.exec("/usr/bin/osascript", ...).

enum AppleScript {
    /// Run an AppleScript or JXA source string. Returns:
    ///   ["ok": Bool, "result": Any, "error": String?]
    /// `result` preserves the script's return type — numbers stay numbers,
    /// lists become arrays, records become objects, strings stay strings,
    /// booleans stay booleans. Matches `hs.osascript` shape (see
    /// hammerspoon/extensions/osascript/NSAppleEventDescriptor+Parsing.m).
    /// Void returns coerce to "" so existing callers see a stable shape.
    /// `language` is "applescript" (default) or "javascript".
    static func run(source: String, language: String = "applescript",
                    timeoutSeconds: Double = 10) -> [String: Any] {
        let langName = (language == "javascript") ? "JavaScript" : "AppleScript"
        guard let lang = OSALanguage(forName: langName) else {
            return ["ok": false, "result": "", "error": "language not available: \(langName)"]
        }
        let script = OSAScript(source: source, language: lang)
        var error: NSDictionary?
        let desc = script.executeAndReturnError(&error)
        if let error = error {
            let msg = (error[OSAScriptErrorMessageKey] as? String)
                ?? (error[NSAppleScript.errorMessage] as? String)
                ?? "unknown error"
            return ["ok": false, "result": "", "error": msg]
        }
        let value: Any = desc.map { descriptorToJSON($0) } ?? ""
        return ["ok": true, "result": value]
    }

    /// Walk an NSAppleEventDescriptor and produce a JSON-encodable value.
    /// Mirrors hs.osascript's `NSAppleEventDescriptor (GenericObject) objectValue`
    /// category, but in Swift with explicit DescType cases. Anything we don't
    /// recognize falls back to `stringValue` (matches the HS default branch).
    private static func descriptorToJSON(_ d: NSAppleEventDescriptor) -> Any {
        switch d.descriptorType {
        case typeTrue:
            return true
        case typeFalse:
            return false
        case typeBoolean:
            return d.booleanValue
        case typeSInt16, typeUInt16, typeSInt32, typeUInt32, typeSInt64, typeUInt64:
            return Int(d.int32Value)
        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint, type128BitFloatingPoint:
            return d.doubleValue
        case typeUnicodeText, typeUTF8Text, typeText, typeFileURL:
            return d.stringValue ?? ""
        case typeAEList:
            let n = d.numberOfItems
            guard n > 0 else { return [Any]() }
            var arr: [Any] = []
            arr.reserveCapacity(Int(n))
            for i in 1...n {  // AE descriptors are 1-indexed
                if let item = d.atIndex(i) { arr.append(descriptorToJSON(item)) }
            }
            return arr
        case typeAERecord:
            // Records carry their fields under keyASUserRecordFields: an AEList
            // of alternating key/value descriptors. This is the shape HS reads
            // (NSAppleEventDescriptor+Parsing.m :: scriptingUserDefinedRecordWithDescriptor).
            // The older Apple-defined record fields (typeProperty) aren't
            // covered here — that path is rarely hit from script return values
            // and the fall-through `stringValue` keeps it lossy-but-non-fatal.
            var dict: [String: Any] = [:]
            if let userFields = d.forKeyword(AEKeyword(keyASUserRecordFields)) {
                let count = userFields.numberOfItems
                if count >= 2 {
                    var i: Int = 1
                    while i <= count - 1 {
                        if let keyDesc = userFields.atIndex(i),
                           let valDesc = userFields.atIndex(i + 1),
                           let key = keyDesc.stringValue {
                            dict[key] = descriptorToJSON(valDesc)
                        }
                        i += 2
                    }
                }
            }
            return dict
        case typeNull:
            return NSNull()
        default:
            // Includes typeType, typeEnumerated, typeObjectSpecifier, typeAlias,
            // and anything else AppleScript may hand back. stringValue is the
            // same fallback HS uses; nil → "" to keep the value JSON-encodable.
            return d.stringValue ?? ""
        }
    }
}

// One-shot invocation of a macOS Shortcut via the system `shortcuts` CLI.
// Thin wrapper over Proc.exec — centralizes the path + argv layout so
// callers don't reinvent it and a future swap to the Intents framework
// (in-process run, no subprocess) is a one-file change.
//
// The CLI:
//   /usr/bin/shortcuts run "<name>" [--input-path -] [--output-path -]
// reads stdin when --input-path - is supplied and writes the shortcut's
// final "stop and output" value to stdout. Failure modes:
//   - unknown shortcut name → nonzero exit, stderr explains
//   - shortcut exists but errors mid-run → nonzero exit, partial stdout
//   - user has Shortcuts disabled / no library access → CLI prompts (TCC)
// We surface the raw {stdout, stderr, exitCode} dict — caller decides how
// to interpret. exitCode = -1 means launch failure (CLI missing / sandbox).
enum Shortcuts {
    static func run(
        name: String,
        input: String? = nil,
        timeoutSeconds: Double? = nil,
        completion: @escaping ([String: Any]) -> Void
    ) {
        var args = ["run", name]
        if input != nil {
            args.append("--input-path")
            args.append("-")
        }
        args.append("--output-path")
        args.append("-")
        Proc.exec(
            cmd: "/usr/bin/shortcuts",
            args: args,
            input: input,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
    }
}
