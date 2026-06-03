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

        // Reposition all stack panels when display geometry changes
        // (resolution change, monitor hotplug, scale factor flip). Without
        // this, frameFor's compute-once-at-load contract leaves region:menubar
        // and region:fullscreen panels stranded at the OLD screen edges.
        //
        // Dedupe: macOS fires didChangeScreenParameters on events that don't
        // actually change geometry (cursor moves between displays, dock
        // collapse/expand on some macOS versions). Without a guard we'd
        // re-spawn every WKWebView ~10 times per session for nothing —
        // every stack reboots its JS context, sqlite re-opens, timers
        // restart from zero. Hash the screen layout and skip the reload
        // when nothing relevant changed.
        var lastScreenSig: String = ""
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak host] _ in
            let sig = NSScreen.screens.map { s in
                let f = s.frame, vf = s.visibleFrame
                return "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)):"
                     + "\(Int(vf.minX)),\(Int(vf.minY)),\(Int(vf.width)),\(Int(vf.height))"
            }.joined(separator: "|")
            if sig == lastScreenSig { return }
            lastScreenSig = sig
            log("screen parameters changed (sig=\(sig.prefix(60))…) → reload")
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
            // Drop the AX cache for this pid — a destroyed window's AXUIElement
            // may still resolve briefly but actions on it raise -25204.
            // Per-window invalidation — only the destroyed id's cache
            // entry is dropped. Nuking the whole pid map on every
            // helper-window destroy (Terminal Inspector, autocomplete
            // sheets, etc.) caused the AX-window-to-CGWindowID mapping
            // for the app's MAIN window to oscillate between rebuilds.
            WindowsByID.invalidateCache(pid: pid_t(info.pid), windowID: CGWindowID(info.id))
            host?.bang(name: "sd.window.destroyed", detail: WindowsLifecycleObserver.detail(info))
        }

        // Drop the AX-addressability cache when an app fully quits. Per-window
        // destroy events fire too aggressively (Terminal alone spawns + reaps
        // many helper windows per session) and would nuke the sticky-true
        // verdict for the app's MAIN window. Only do it when the pid really
        // is gone — NSWorkspace fires this once per app termination.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: NSWorkspace.shared, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            WindowAddressabilityCache.invalidate(pid: app.processIdentifier)
        }
        WindowsLifecycleObserver.shared.onTitleChange = { [weak host] info, oldTitle in
            log("window title changed: \(info.app) — '\(oldTitle)' → '\(info.title)'")
            var d = WindowsLifecycleObserver.detail(info)
            d["oldTitle"] = oldTitle
            host?.bang(name: "sd.window.titleChanged", detail: d)
        }
        // Lazy: the 1Hz CGWindowList poll only runs while at least one stack
        // declares a sd.window.* handle (subscribe + scope.adopt happens in
        // StackHost.spawnInstance). With no listeners, daemon idle cost is 0.

        // CGS connection-notify window events: faster + earlier than the 1Hz
        // poll above, and they cover events the poll can't see (moved, resized,
        // minimized, deminimized, reordered, focusedByMouse). SkyLight has no
        // removeNotifyProc, so this is install-once for the process lifetime;
        // the host.bang fan-out inside the callback is a no-op when no stack
        // handles the bang. See Sources/DataSources/WindowEvents.swift for
        // event IDs and payload decoding.
        WindowEvents.install()
        // macOS 26 (Tahoe) lost CGS events 806/807/815/816 — moved, resized,
        // minimized, deminimized. Without these, drag-to-resize and the
        // minimize-bang-driven exclusion in tilers can't work. A 250ms CG
        // diff loop synthesizes the same bangs; idempotent on pre-Tahoe
        // where the native events still fire.
        WindowEvents.startTahoeSynthPoll()

        // Display hotplug bangs (added/removed/reconfigured). Same lifetime
        // pattern as WindowEvents — install once at startup; CG fans out per
        // change, host.bang is a no-op when no stack handles the bang.
        DisplayHotplug.install()

        // Mission Control state bangs (entered/exited + the three "show"
        // gestures). "Entered" is the CGS 1204 event already wired in
        // Spaces.swift; this installs the Dock AX observer that surfaces the
        // exit / show-all-windows / show-front-windows / show-desktop notifs.
        MissionControl.install()

        // Disk mount / unmount bangs. DiskArbitration session lives for the
        // process; the appeared callback fires once per already-mounted
        // volume at install time so late-loaded stacks still see the disks
        // that were attached before stackd started.
        DisksHotplug.install()
    }

    func applicationWillTerminate(_ note: Notification) {
        // Safety: never leave the user's menu bar hidden if we exit while suppressing.
        MenuBarVisibility.resetForReload()
        watcher?.stop()
        ipc?.stop()
    }
}
