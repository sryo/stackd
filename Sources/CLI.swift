import Foundation

enum CLI {
    static let helpText = """
    stackd <verb> [args]
      list                                      list running stack IDs
      reload                                    tear down & reload all stacks from disk
      toggle <id>                               enable/disable a single stack
      set <id|/regex/> --css <prop>=<value>     set a CSS custom property on one or many stacks
      bang <name> [KEY=VAL ...]                 fire a bang to stacks that handle it
      help                                      this text

    Selectors:
      <id>          exact match, e.g. battery
      /pattern/     regex, e.g. /^c/ matches every stack id starting with 'c'

    Defaults:
      defaults.json at the stackd root is shallow-merged under every stack
      manifest before decoding. Useful for global permissions, anchors, etc.

    The daemon must be running. Start it with:
      stackd                                    (no args)
    """

    static func runClient(_ args: [String]) -> Int32 {
        let result = IPCClient.send(argv: args)
        FileHandle.standardOutput.write(result.response.data(using: .utf8) ?? Data())
        return result.status
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
        var detail: [String: String] = [:]
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
