import Foundation

enum CLI {
    static let helpText = """
    stackd <verb> [args]
      list                                      list running stack IDs
      reload                                    tear down & reload all stacks from disk
      toggle <id>                               enable/disable a single stack
      set <id|/regex/> --css <prop>=<value>     set a CSS custom property on one or many stacks
      bang <name> [KEY=VAL ...]                 fire a bang to stacks that handle it
      new <name> [--template <t>]               scaffold a new stack at ~/stackd/stacks/<name>/
      doctor                                    validate every stack manifest in ~/stackd/stacks/
      help                                      this text

    Selectors:
      <id>          exact match, e.g. battery
      /pattern/     regex, e.g. /^c/ matches every stack id starting with 'c'

    Defaults:
      defaults.json at the stackd root is shallow-merged under every stack
      manifest before decoding. Useful for global permissions, anchors, etc.

    The daemon must be running for verbs that talk to live stacks (list,
    reload, toggle, set, bang). `new` and `doctor` are local file ops and
    work without the daemon. Start the daemon with:
      stackd                                    (no args)
    """

    static func runClient(_ args: [String]) -> Int32 {
        // Verbs that don't need the daemon — pure file IO. FSEvents will
        // pick up the new files and trigger a reload automatically once the
        // daemon comes back online (or is already running).
        if let verb = args.first {
            switch verb {
            case "new":    return runNew(Array(args.dropFirst()))
            case "doctor": return runDoctor()
            default: break
            }
        }
        let result = IPCClient.send(argv: args)
        FileHandle.standardOutput.write(result.response.data(using: .utf8) ?? Data())
        return result.status
    }

    // MARK: - new (scaffolder)

    private static func runNew(_ args: [String]) -> Int32 {
        guard let name = args.first, !name.isEmpty else {
            FileHandle.standardError.write(Data("usage: stackd new <name> [--template <hello>]\n".utf8))
            return 2
        }
        guard isSafeId(name) else {
            FileHandle.standardError.write(Data("stackd: invalid name '\(name)' — use letters, numbers, dashes, underscores only\n".utf8))
            return 2
        }
        var template = "hello"
        var i = 1
        while i < args.count {
            if args[i] == "--template", i + 1 < args.count { template = args[i + 1]; i += 2 }
            else { i += 1 }
        }
        guard let files = StackTemplates.all[template] else {
            FileHandle.standardError.write(Data("stackd: unknown template '\(template)'. Available: \(StackTemplates.all.keys.sorted().joined(separator: ", "))\n".utf8))
            return 2
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = home + "/stackd/stacks/" + name
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: root, isDirectory: &isDir) {
            FileHandle.standardError.write(Data("stackd: \(root) already exists — refusing to overwrite\n".utf8))
            return 1
        }
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            for (relativePath, contents) in files {
                let body = contents.replacingOccurrences(of: "{{name}}", with: name)
                let full = root + "/" + relativePath
                let parent = (full as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try body.write(toFile: full, atomically: true, encoding: .utf8)
            }
        } catch {
            FileHandle.standardError.write(Data("stackd: write failed: \(error)\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(Data("created \(root)\n  edit \(root)/index.html and save — the daemon hot-reloads automatically.\n".utf8))
        return 0
    }

    private static func isSafeId(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix(".") else { return false }
        for c in s where !(c.isLetter || c.isNumber || c == "-" || c == "_") { return false }
        return true
    }

    // MARK: - doctor (manifest validator)

    private static func runDoctor() -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stacksDir = home + "/stackd/stacks"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stacksDir) else {
            FileHandle.standardError.write(Data("stackd: no stacks dir at \(stacksDir)\n".utf8))
            return 1
        }
        var issues = 0
        var checked = 0
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = stacksDir + "/" + entry
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            checked += 1
            issues += StackDoctor.check(stackDir: path)
        }
        FileHandle.standardOutput.write(Data("\nchecked \(checked) stack(s), \(issues) issue(s).\n".utf8))
        return issues == 0 ? 0 : 1
    }

    static func dispatch(argv: [String], host: StackHost) -> String {
        guard let verb = argv.first else { return helpText + "\n" }
        let rest = Array(argv.dropFirst())
        switch verb {
        case "list":
            let ids = host.listStacks()
            return ids.isEmpty ? "(no stacks loaded)\n" : ids.joined(separator: "\n") + "\n"
        case "reload":
            host.reloadAll()
            return "reloaded \(host.listStacks().count) stack(s)\n"
        case "toggle":
            guard let id = rest.first else { return "usage: toggle <stack-id>\n" }
            return host.toggle(id: id)
        case "set":
            return handleSet(rest, host)
        case "bang":
            return handleBang(rest, host)
        case "help", "-h", "--help":
            return helpText + "\n"
        default:
            return "error: unknown verb: \(verb)\n" + helpText + "\n"
        }
    }

    private static func handleSet(_ args: [String], _ host: StackHost) -> String {
        guard args.count >= 3, args[1] == "--css" else {
            return "usage: set <stack-id|/regex/> --css <prop>=<value>\n"
        }
        let selector = args[0]
        let assignment = args[2]
        guard let eq = assignment.firstIndex(of: "=") else {
            return "error: expected --css <prop>=<value>\n"
        }
        let prop = String(assignment[..<eq])
        let value = String(assignment[assignment.index(after: eq)...])

        let targets = matchStacks(selector: selector, host: host)
        if targets.isEmpty {
            return "error: no stack matched: \(selector)\n"
        }
        var hits = 0
        for id in targets {
            if host.setCSS(stackId: id, property: prop, value: value) { hits += 1 }
        }
        return "ok (\(hits)/\(targets.count) \(targets.joined(separator: ",")))\n"
    }

    private static func handleBang(_ args: [String], _ host: StackHost) -> String {
        guard let name = args.first else {
            return "usage: bang <name> [KEY=VAL ...]\n"
        }
        var detail: [String: Any] = [:]
        for kv in args.dropFirst() {
            if let eq = kv.firstIndex(of: "=") {
                detail[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
        }
        let count = host.bang(name: name, detail: detail)
        return "fired '\(name)' to \(count) stack(s)\n"
    }

    private static func matchStacks(selector: String, host: StackHost) -> [String] {
        if selector.hasPrefix("/") && selector.hasSuffix("/") && selector.count >= 2 {
            let pattern = String(selector.dropFirst().dropLast())
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return host.listStacks().filter { id in
                let r = NSRange(id.startIndex..., in: id)
                return re.firstMatch(in: id, range: r) != nil
            }
        }
        return host.listStacks().contains(selector) ? [selector] : []
    }
}
