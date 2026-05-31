import AppKit

// Which app is frontmost. Window-related code (focused window, lifecycle,
// per-id actions, focus observer) lives in Windows.swift — they all share
// the AX + CGWindowList machinery and benefit from being colocated.

final class WorkspaceObserver: RefCountedObserver {
    static let shared = WorkspaceObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.fire() }
        return Token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}

enum Workspace {
    static func frontmostApp() -> [String: Any]? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return [
            "pid": Int(app.processIdentifier),
            "name": app.localizedName ?? "",
            "bundleId": app.bundleIdentifier ?? "",
            "active": app.isActive
        ]
    }
}

/* Windows enum + WindowsByID + WindowsLifecycleObserver + FrontmostWindowObserver
   all live in Windows.swift now. Each was in a separate file pre-consolidation:
   Workspace.swift (Windows enum) + WindowsByID.swift + WindowsLifecycle.swift +
   AXObserver.swift (FrontmostWindowObserver). One domain, one file.

   The placeholder block below is REMOVED — see git history for the original
   `enum Windows` definition. */
