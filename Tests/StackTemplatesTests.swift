import Foundation

// `stackd new` scaffolds: a freshly scaffolded stack must load, pass
// `stackd doctor` cleanly, follow the daemon-owns-chrome rule and only call
// sd.* members the runtime builds. Templates are materialized the way
// CLI.runNew writes them ({{name}} → the stack id), into a temp root.

private func scaffold(_ files: [String: String], name: String, in root: String) throws -> String {
    let dir = root + "/" + name
    for (relativePath, contents) in files {
        let full = dir + "/" + relativePath
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try contents.replacingOccurrences(of: "{{name}}", with: name)
            .write(toFile: full, atomically: true, encoding: .utf8)
    }
    return dir
}

func registerStackTemplatesTests() {
    test("stackd new: every template scaffolds a stack that loads and passes doctor") {
        let root = NSTemporaryDirectory() + "stackd-templates-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        for (template, files) in StackTemplates.all.sorted(by: { $0.key < $1.key }) {
            let dir = try scaffold(files, name: "scaffold-\(template)", in: root)
            try expect(StackSource.loadFolder(at: dir, defaults: [:]) != nil,
                       "template '\(template)': stack.json doesn't decode")
            let issues = StackCompat.silencingStdout { StackDoctor.check(stackDir: dir) }
            try expectEqual(issues, 0, "template '\(template)': doctor issues")
        }
    }

    test("stackd new: no template ships CSS backdrop-filter (manifest material owns the blur)") {
        for (template, files) in StackTemplates.all {
            for (path, body) in files where StackCompat.stripComments(body).contains("backdrop-filter") {
                throw Expectation(message: "template '\(template)' \(path) uses backdrop-filter")
            }
        }
    }

    test("stackd new: templates only reference sd.* members the runtime builds") {
        let surface = StackCompat.Resolver(PublicSurface.runtimeEntries())
        for (template, files) in StackTemplates.all {
            let refs = StackCompat.references(in: files.values.joined(separator: "\n"))
            let missing = refs.filter { !surface.resolves($0) }.sorted()
            try expect(missing.isEmpty, "template '\(template)' references \(missing)")
        }
    }
}
