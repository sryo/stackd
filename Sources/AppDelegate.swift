import AppKit

func log(_ s: String) {
    FileHandle.standardError.write(Data("stackd: \(s)\n".utf8))
}

/// The user's drop folder. Stacks live here. Default: ~/stackd.
/// Override with STACKD_ROOT.
func stackdRoot() -> String {
    let path: String
    if let env = ProcessInfo.processInfo.environment["STACKD_ROOT"] {
        path = (env as NSString).expandingTildeInPath
    } else {
        path = (ProcessInfo.processInfo.environment["HOME"] ?? "/tmp") + "/stackd"
    }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: path + "/stacks", withIntermediateDirectories: true)
    return path
}

/// Stdlib location (api.js etc.) — ships with the daemon, NOT in the user folder.
/// Looks for Runtime/ next to the binary (dev: symlinked by build.sh into .build/;
/// prod: would live in Contents/Resources/ inside an .app). STACKD_RUNTIME overrides.
func runtimePath() -> String {
    if let env = ProcessInfo.processInfo.environment["STACKD_RUNTIME"] {
        return (env as NSString).expandingTildeInPath
    }
    if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
        let bundled = exe.appendingPathComponent("Runtime").path
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
    }
    return "/tmp/stackd-runtime-missing"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var host: StackHost?
    var ipc: IPCServer?
    var watcher: FileWatcher?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Never inherit a "menu bar hidden" state from a crashed previous daemon.
        MenuBarVisibility.forceRestoreOnLaunch()

        let root = stackdRoot()
        let runtime = runtimePath()
        let host = StackHost(rootPath: root, runtimePath: runtime)
        host.discoverAndLoad()
        self.host = host

        let ipc = IPCServer()
        ipc.dispatcher = { [weak host] argv in
            guard let host = host else { return "error: host not ready\n" }
            return CLI.dispatch(argv: argv, host: host)
        }
        do {
            try ipc.start()
        } catch {
            log("ipc failed: \(error.localizedDescription)")
        }
        self.ipc = ipc

        // Watch user content AND the runtime symlink target — both auto-reload on save.
        self.watcher = FileWatcher(paths: [
            root + "/stacks",
            root + "/defaults.json",
            runtime
        ]) { [weak host] in
            log("file change → reload")
            host?.reloadAll()
        }

        // Wire window lifecycle → bangs. Polling at 1s; stacks subscribe via
        // manifest handles: ["sd.window.created" | "destroyed" | "titleChanged"].
        WindowsLifecycleObserver.shared.onCreate = { [weak host] info in
            log("window created: \(info.app) — \(info.title) (id=\(info.id))")
            host?.bang(name: "sd.window.created", detail: WindowsLifecycleObserver.detail(info))
        }
        WindowsLifecycleObserver.shared.onDestroy = { [weak host] info in
            log("window destroyed: \(info.app) — \(info.title) (id=\(info.id))")
            host?.bang(name: "sd.window.destroyed", detail: WindowsLifecycleObserver.detail(info))
        }
        WindowsLifecycleObserver.shared.onTitleChange = { [weak host] info, oldTitle in
            log("window title changed: \(info.app) — '\(oldTitle)' → '\(info.title)'")
            var d = WindowsLifecycleObserver.detail(info)
            d["oldTitle"] = oldTitle
            host?.bang(name: "sd.window.titleChanged", detail: d)
        }
        WindowsLifecycleObserver.shared.start()
    }

    func applicationWillTerminate(_ note: Notification) {
        // Safety: never leave the user's menu bar hidden if we exit while suppressing.
        MenuBarVisibility.resetForReload()
        watcher?.stop()
        ipc?.stop()
    }
}
