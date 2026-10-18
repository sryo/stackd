import Foundation

// NSWorkspace posts its notifications (didTerminateApplication,
// activeSpaceDidChange, didWake, …) on NSWorkspace.shared.notificationCenter
// only, and NSApplication posts its own on NotificationCenter.default. An
// observer on the other center registers fine and never fires, so every
// unit test stays green while the feature is dead. Observer registration
// needs a real app or workspace event to exercise, so this is a source
// check over Sources/: it sees direct registrations, not a center held in
// a variable.

private let wrongCenter: [NSRegularExpression] = [
    #"NotificationCenter\.default\s*\.\s*(addObserver|publisher)\(\s*(forName|for):\s*NSWorkspace\.\w+Notification"#,
    #"\(\s*NotificationCenter\.default\s*,\s*NSWorkspace\.\w+Notification"#,
    #"NSWorkspace\.shared\.notificationCenter\s*\.\s*(addObserver|publisher)\(\s*(forName|for):\s*NSApplication\.\w+Notification"#,
    #"\(\s*NSWorkspace\.shared\.notificationCenter\s*,\s*NSApplication\.\w+Notification"#,
].map { try! NSRegularExpression(pattern: $0) }

/// `<label>:<line>` for every wrong-center registration in `text`.
private func wrongCenterHits(in text: String, label: String) -> [String] {
    let ns = text as NSString
    return wrongCenter.flatMap { re in
        re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            "\(label):\(ns.substring(to: m.range.location).components(separatedBy: "\n").count)"
        }
    }
}

func registerWorkspaceNotificationsTests() {
    test("NSWorkspace notifications are observed on the workspace center, NSApplication ones on .default") {
        var hits: [String] = []
        for file in SourceScan.files(in: "Sources", exts: ["swift"]) {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            hits += wrongCenterHits(in: text, label: file)
        }
        try expect(hits.isEmpty, "observer on the wrong notification center (it will never fire): \(hits)")
    }

    test("the wrong-center check recognizes each registration shape it guards") {
        let samples = [
            // A registration split across lines.
            """
            NotificationCenter.default.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in }
            """,
            "installNotifications([(NotificationCenter.default, NSWorkspace.didWakeNotification)])",
            "NSWorkspace.shared.notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { _ in }",
        ]
        for s in samples {
            try expectEqual(wrongCenterHits(in: s, label: "sample").count, 1, s)
        }
        let right = "NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in }"
        try expectEqual(wrongCenterHits(in: right, label: "sample"), [])
    }
}
