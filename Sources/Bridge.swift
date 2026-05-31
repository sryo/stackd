import WebKit

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var permissions: [String] = []
    private var lastBattery: String?
    private var lastMouse: String?
    private var lastFrontApp: String?
    private var lastFocusedWindow: String?
    private var lastWindowsAll: String?
    private var lastAppearance: String?
    private var lastInput: String?
    private var lastNetWifi: String?
    private var lastNetLan: String?
    private var lastAudio: String?
    private var lastDisplay: String?
    private var lastMedia: String?
    private var lastPasteboard: String?
    private var lastApps: String?
    // Parsed snapshot used to compute the sd.apps.changed delta — keyed by
    // bundleId because pids recycle but bundleIds are stable across launches.
    private var lastAppsByBundle: [String: [String: Any]] = [:]
    private var lastSpaces: String?
    private var lastCaffeinate: String?
    private var lastLocation: String?
    private var lastUSB: String?
    private var lastCamera: String?
    private var settings: StackSettings?
    private var fsWatches: [Int: FSWatch] = [:]
    private var handlesBangs: Set<String> = []
    private let axHandles = AX.HandleStore()
    // Outstanding sd.menubar.suppress() tokens (LIFO). sd.menubar.restore()
    // pops one. Anything left at unload is drained by scope.
    private var menubarSuppressions: [Token] = []
    // NSStatusItem handles owned by this stack, keyed by mint id. Scope adopts
    // a drain entry at start(); unload removes every item from NSStatusBar.
    fileprivate var statusItems: [Int: StatusItemHandle] = [:]
    fileprivate var nextStatusItemId: Int = 1
    // JS-bound Carbon hotkeys: id → Token. Each Token's cancel removes the
    // Carbon registration; scope drains them on unload too. The JS side keeps
    // its own map keyed by the same id so __sd_hotkey_fire can find the callback.
    fileprivate var hotkeyTokens: [Int: Token] = [:]
    fileprivate var nextHotkeyId: Int = 1
    // JS-bound DN observers: id → Token. Scope drains them on unload.
    fileprivate var dnTokens: [Int: Token] = [:]
    fileprivate var nextDnId: Int = 1
    /// Per-stack native-resource scope. Every observer subscription, hotkey
    /// bind, eventtap register, menubar suppression goes in here. StackHost
    /// calls drain() on unload to release them all in reverse order.
    let scope = StackScope()

    private static let consoleHookScript: WKUserScript = {
        let source = """
        (function() {
          const send = (level, args) => {
            try {
              window.webkit.messageHandlers.log.postMessage({
                level, msg: args.map(a => {
                  try { return typeof a === 'string' ? a : JSON.stringify(a); }
                  catch { return String(a); }
                }).join(' ')
              });
            } catch (e) {}
          };
          const orig = { log: console.log, warn: console.warn, error: console.error };
          console.log   = (...a) => { send('log', a);   orig.log.apply(console, a); };
          console.warn  = (...a) => { send('warn', a);  orig.warn.apply(console, a); };
          console.error = (...a) => { send('error', a); orig.error.apply(console, a); };
          window.addEventListener('error', e => send('error', [e.message, e.filename + ':' + e.lineno]));
          window.addEventListener('unhandledrejection', e => send('error', ['unhandledrejection', String(e.reason)]));
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    init(webView: WKWebView, screen: NSScreen? = nil, screenIndex: Int = 0) {
        self.webView = webView
        super.init()
        let ucc = webView.configuration.userContentController
        ucc.add(self, name: "sd")
        ucc.add(self, name: "log")
        ucc.addUserScript(Bridge.consoleHookScript)
        // Per-instance window.__sd_screen so items like spacenum + brightness
        // can target the screen they're rendered on. Injected at document
        // start so it's visible before any module script runs.
        if let scr = screen {
            let payload = Bridge.jsonify(Bridge.screenInfo(screen: scr, index: screenIndex))
            let source = "window.__sd_screen = \(payload);"
            let inject = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            ucc.addUserScript(inject)
        }
    }

    static func screenInfo(screen: NSScreen, index: Int) -> [String: Any] {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let uuid: String = {
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
            return CFUUIDCreateString(nil, cf) as String? ?? ""
        }()
        return [
            "uuid":         uuid,
            "displayID":    Int(id),
            "index":        index,
            "frame":        rect(screen.frame),
            "visibleFrame": rect(screen.visibleFrame)
        ]
    }

    private static func rect(_ r: CGRect) -> [String: Int] {
        ["x": Int(r.origin.x), "y": Int(r.origin.y),
         "w": Int(r.size.width), "h": Int(r.size.height)]
    }

    func start(manifest: StackManifest) {
        self.permissions = manifest.permissions
        self.handlesBangs = Set(manifest.handles ?? [])
        self.settings = StackSettings(stackId: manifest.id)
        // Keep WindowsLifecycleObserver's 1Hz CGWindowList poll alive only
        // while at least one loaded stack declares it cares (handles a
        // sd.window.* bang). Token drains with the scope on unload.
        if handlesBangs.contains(where: { $0.hasPrefix("sd.window.") }) {
            scope.adopt(WindowsLifecycleObserver.shared.subscribe())
        }
        if manifest.permissions.contains("battery")    { startBattery() }
        if manifest.permissions.contains("mouse")      { startMouse() }
        if manifest.permissions.contains("appearance") { startAppearance() }
        if manifest.permissions.contains("input")      { startInput() }
        if manifest.permissions.contains("net")        { startNetwork() }
        if manifest.permissions.contains("audio")      { startAudio() }
        if manifest.permissions.contains("display")    { startDisplay() }
        if manifest.permissions.contains("media")      { startMedia() }
        if manifest.permissions.contains("pasteboard") { startPasteboard() }
        if manifest.permissions.contains("apps")       { startApps() }
        if manifest.permissions.contains("spaces")     { startSpaces() }
        if manifest.permissions.contains("caffeinate") { startCaffeinate() }
        if manifest.permissions.contains("location")   { startLocation() }
        if manifest.permissions.contains("usb")        { startUSB() }
        if manifest.permissions.contains("camera")     { startCamera() }
        if manifest.permissions.contains("app") || manifest.permissions.contains("windows") {
            startWorkspace(includeApp: manifest.permissions.contains("app"),
                           includeWindows: manifest.permissions.contains("windows"))
        }
        if let hks = manifest.hotkeys {
            for hk in hks {
                let cb = hk.callback
                scope.adopt(HotkeyRegistry.shared.bind(spec: hk.key) { [weak self] in
                    self?.fireHotkey(callback: cb)
                })
            }
        }
        if let taps = manifest.eventtap {
            for et in taps {
                guard let type = EventTapRegistry.parse(et.event) else {
                    FileHandle.standardError.write(Data("stackd: unknown eventtap type \(et.event)\n".utf8))
                    continue
                }
                let cb = et.callback
                scope.adopt(EventTapRegistry.shared.register(eventType: type) { [weak self] event in
                    self?.fireEventTap(callback: cb, type: type, event: event)
                })
            }
        }
        // Drain any leftover sd.menubar.suppress() tokens. If the stack
        // paired suppress/restore correctly this is a no-op; if it crashed
        // mid-suppress this is the safety net so the bar reappears.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for t in self.menubarSuppressions { t.cancel() }
            self.menubarSuppressions.removeAll()
        })
        // Same shape for NSStatusItems: stack unload removes every item this
        // stack added (no orphan icons sitting in the menu bar forever).
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, h) in self.statusItems { h.remove() }
            self.statusItems.removeAll()
        })
        // Same shape for JS-bound hotkeys: stack unload cancels every Carbon
        // registration so reload-then-rebind doesn't leak duplicate bindings.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.hotkeyTokens { t.cancel() }
            self.hotkeyTokens.removeAll()
        })
        // Same shape for JS-bound DN observers — drop every NSObject observer
        // this stack registered with DistributedNotificationCenter on unload.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.dnTokens { t.cancel() }
            self.dnTokens.removeAll()
        })
    }

    func handles(bang: String) -> Bool { handlesBangs.contains(bang) }

    /// Detail can hold any JSON-compatible Any (String, Int, Bool, Array, Dict).
    /// Useful for system-fired bangs (window lifecycle) carrying structured
    /// data — CLI-fired bangs still pass [String: String] which round-trips fine.
    func fireBang(name: String, detail: [String: Any]) {
        guard let webView = webView else { return }
        let safe = name.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "_"
        }
        let suffix = String(safe)
        let json = Bridge.jsonify(detail)
        let script = "window.onBang_\(suffix) && window.onBang_\(suffix)(\(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - Message dispatch

    // Single entry point: look up the type in the static `dispatch` table,
    // gate on `permission` if declared, then call the primitive's handler.
    // Adding a new primitive is one entry in the table below — no edits to
    // userContentController, no per-call permission boilerplate.
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "log", let body = message.body as? [String: Any] {
            let level = body["level"] as? String ?? "log"
            let msg = body["msg"] as? String ?? ""
            FileHandle.standardError.write(Data("stackd: js[\(level)] \(msg)\n".utf8))
            return
        }
        guard message.name == "sd",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let primitive = Bridge.dispatch[type] else { return }
        let requestId = body["requestId"] as? Int ?? -1
        if let perm = primitive.permission, !permissions.contains(perm) {
            // Single-line guidance: the manifest is right there in the stack
            // folder; this tells the author exactly what to add.
            log("\(type) denied — add \"\(perm)\" to permissions in stack.json")
            // Per-primitive denial value (false for void/Bool-returning, NSNull
            // for nullable readers). Matches the pre-refactor handler-per-type
            // shape so existing stacks see the same shape they always did.
            respond(requestId: requestId, value: primitive.denyValue)
            return
        }
        primitive.handler(self, body, requestId)
    }

    /// JSON-encode a value (or "null") and fire window.__sd_response(requestId, value).
    fileprivate func respond(requestId: Int, value: Any?) {
        guard let webView = webView else { return }
        let json = value.map { Bridge.jsonify($0) } ?? "null"
        let script = "window.__sd_response && window.__sd_response(\(requestId), \(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - Primitive table

    /// Declarative dispatch entry. Each `Primitive` ties a JS-side type string
    /// to its permission gate (nil = always allowed) and a handler. Builder
    /// helpers below remove the requestId / permission / respond boilerplate
    /// for the ~60 sync entries; the messy 6 (proc.exec, fs.watch.*, menu.popup,
    /// window.invoke/dismiss, bang) use `.custom` for raw control.
    struct Primitive {
        let type: String
        let permission: String?
        /// Value sent to JS when this primitive is denied for lack of permission.
        /// Defaults to NSNull (matches pure readers). Boolean side-effect entries
        /// like audio.setVolume use `false` so existing stacks that wrote
        /// `if (await sd.audio.setVolume(v) === false)` keep working.
        let denyValue: Any
        let handler: (Bridge, [String: Any], Int) -> Void

        /// Sync — closure returns a JSON-able value (or nil); auto-respond.
        static func sync(_ type: String, permission: String? = nil, denyValue: Any = NSNull(),
                         _ handler: @escaping ([String: Any]) -> Any?) -> Primitive {
            Primitive(type: type, permission: permission, denyValue: denyValue) { bridge, body, requestId in
                bridge.respond(requestId: requestId, value: handler(body))
            }
        }

        /// Sync that needs Bridge (for settings, fsWatches, menubarSuppressions).
        static func syncBridge(_ type: String, permission: String? = nil, denyValue: Any = NSNull(),
                               _ handler: @escaping (Bridge, [String: Any]) -> Any?) -> Primitive {
            Primitive(type: type, permission: permission, denyValue: denyValue) { bridge, body, requestId in
                bridge.respond(requestId: requestId, value: handler(bridge, body))
            }
        }

        /// AX traffic must hop to main: AXUIElement APIs claim thread safety
        /// but real apps deadlock under cross-thread calls.
        static func ax(_ type: String, permission: String? = "ax", denyValue: Any = NSNull(),
                       _ handler: @escaping (Bridge, [String: Any]) -> Any?) -> Primitive {
            Primitive(type: type, permission: permission, denyValue: denyValue) { bridge, body, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    guard let bridge = bridge else { return }
                    bridge.respond(requestId: requestId, value: handler(bridge, body))
                }
            }
        }

        /// Raw access for async / unusual entries: proc.exec, fs.watch.start,
        /// menu.popup, window.invoke/dismiss, bang. The handler is responsible
        /// for calling respond() (possibly later, possibly never).
        static func custom(_ type: String, permission: String? = nil, denyValue: Any = NSNull(),
                           _ handler: @escaping (Bridge, [String: Any], Int) -> Void) -> Primitive {
            Primitive(type: type, permission: permission, denyValue: denyValue, handler: handler)
        }
    }

    private static let primitives: [Primitive] = [
        // Bootstrap
        .custom("ready") { bridge, _, _ in bridge.replayState() },

        // Defaults
        .sync("defaults.read", permission: "defaults") { body in
            Defaults.read(bundleId: body["bundleId"] as? String ?? "",
                          key:      body["key"]      as? String ?? "")
        },

        // Audio — Bool side-effect ops, deny → false.
        .sync("audio.setVolume", permission: "audio", denyValue: false) { body in
            Audio.setVolume(Float((body["value"] as? Double) ?? 0))
        },
        .sync("audio.setMuted", permission: "audio", denyValue: false) { body in
            Audio.setMuted((body["value"] as? Bool) ?? false)
        },

        // Display
        .sync("display.setBrightness", permission: "display", denyValue: false) { body in
            Display.setBrightness(
                displayID: CGDirectDisplayID((body["displayID"] as? Int) ?? 0),
                Float((body["value"] as? Double) ?? 0))
        },

        // Menubar suppression — refcounted via per-Bridge stack of tokens.
        .syncBridge("menubar.suppress", permission: "menubar", denyValue: false) { bridge, _ in
            guard let token = MenuBarVisibility.suppress() else { return false }
            bridge.menubarSuppressions.append(token)
            return true
        },
        .syncBridge("menubar.restore", permission: "menubar", denyValue: false) { bridge, _ in
            guard let t = bridge.menubarSuppressions.popLast() else { return false }
            t.cancel(); return true
        },

        // Media
        .sync("media.command", permission: "media", denyValue: false) { body in
            Media.command(body["name"] as? String ?? "")
        },

        // Per-stack settings (k/v scoped to this stack's id). Write-style ops
        // (set/delete) deny → false; get → null; all → empty dict (matches
        // pre-refactor handler returns).
        .syncBridge("settings.get",    permission: "settings") { b, body in b.settings?.get(body["key"] as? String ?? "") as Any? },
        .syncBridge("settings.set",    permission: "settings", denyValue: false) { b, body in b.settings?.set(body["key"] as? String ?? "", body["value"]); return true },
        .syncBridge("settings.delete", permission: "settings", denyValue: false) { b, body in b.settings?.delete(body["key"] as? String ?? ""); return true },
        .syncBridge("settings.all",    permission: "settings", denyValue: [String: Any]()) { b, _ in b.settings?.all() ?? [:] },

        // Filesystem
        .sync("fs.read", permission: "fs") { body in FS.read(path: body["path"] as? String ?? "") },
        .sync("fs.stat", permission: "fs") { body in FS.stat(path: body["path"] as? String ?? "") },
        .sync("fs.list", permission: "fs") { body in
            FS.list(dir: body["dir"] as? String ?? "", includeHidden: body["hidden"] as? Bool ?? false)
        },
        .sync("fs.write", permission: "fs", denyValue: false) { body in
            FS.write(path: body["path"] as? String ?? "", contents: body["contents"] as? String ?? "")
        },
        .sync("fs.mkdir", permission: "fs", denyValue: false) { body in
            FS.mkdir(path: body["path"] as? String ?? "")
        },
        .sync("fs.delete", permission: "fs", denyValue: false) { body in
            FS.delete(path: body["path"] as? String ?? "")
        },
        .sync("fs.move", permission: "fs", denyValue: false) { body in
            FS.move(from: body["from"] as? String ?? "", to: body["to"] as? String ?? "")
        },
        .custom("fs.watch.start", permission: "fs", denyValue: false) { bridge, body, requestId in
            let path = body["path"] as? String ?? ""
            let watchId = body["watchId"] as? Int ?? -1
            let watch = FSWatch(paths: [path]) { [weak bridge] events in
                bridge?.dispatchFsEvents(watchId: watchId, events: events)
            }
            guard let w = watch else { bridge.respond(requestId: requestId, value: false); return }
            bridge.fsWatches[watchId] = w
            bridge.respond(requestId: requestId, value: true)
        },
        .custom("fs.watch.stop", permission: "fs", denyValue: false) { bridge, body, requestId in
            let watchId = body["watchId"] as? Int ?? -1
            if let w = bridge.fsWatches.removeValue(forKey: watchId) {
                w.stop(); bridge.respond(requestId: requestId, value: true)
            } else {
                bridge.respond(requestId: requestId, value: false)
            }
        },

        // Pasteboard
        .sync("pasteboard.get", permission: "pasteboard") { _ in Pasteboard.getString() },
        .sync("pasteboard.set", permission: "pasteboard", denyValue: false) { body in
            Pasteboard.setString(body["value"] as? String ?? "")
        },

        // Native banner notifications via osascript display notification.
        // Fire-and-forget — see Notify.swift for the bundle-id rationale.
        .sync("notify.show", permission: "notify", denyValue: false) { body in
            Notify.show(
                title:    body["title"]    as? String ?? "",
                body:     body["body"]     as? String ?? "",
                subtitle: body["subtitle"] as? String,
                sound:    body["sound"]    as? String
            )
        },

        // Process exec — async; respond from the completion callback.
        .custom("proc.exec", permission: "proc") { bridge, body, requestId in
            Proc.exec(
                cmd:     body["cmd"]   as? String ?? "",
                args:    body["args"]  as? [String] ?? [],
                input:   body["input"] as? String,
                timeoutSeconds: body["timeout"] as? Double
            ) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result)
            }
        },

        // Event synthesis — Bool side-effect ops, deny → false.
        .sync("events.type", permission: "events", denyValue: false) { body in
            EventsSynth.type(body["value"] as? String ?? ""); return true
        },
        .sync("events.key", permission: "events", denyValue: false) { body in
            EventsSynth.key(body["spec"] as? String ?? "")
        },
        .sync("events.scroll", permission: "events", denyValue: false) { body in
            EventsSynth.scroll(
                dx: Int32(body["dx"] as? Int ?? 0),
                dy: Int32(body["dy"] as? Int ?? 0))
        },
        .sync("events.click", permission: "events", denyValue: false) { body in
            EventsSynth.click(
                x: body["x"] as? Double ?? 0,
                y: body["y"] as? Double ?? 0,
                button: body["button"] as? String ?? "left")
        },

        // Apps — Bool side-effect ops, deny → false.
        .sync("apps.launch", permission: "apps", denyValue: false) { body in Apps.launch(bundleId: body["bundleId"] as? String ?? "") },
        .sync("apps.focus",  permission: "apps", denyValue: false) { body in Apps.focus( bundleId: body["bundleId"] as? String ?? "") },
        .sync("apps.kill",   permission: "apps", denyValue: false) { body in Apps.kill(  bundleId: body["bundleId"] as? String ?? "", force: body["force"] as? Bool ?? false) },
        .sync("apps.hide",   permission: "apps", denyValue: false) { body in Apps.hide(  bundleId: body["bundleId"] as? String ?? "") },

        // Icons
        .sync("icons.app",  permission: "icons") { body in
            Icons.forApp( bundleId: body["bundleId"] as? String ?? "", size: body["size"] as? Int ?? 64)
        },
        .sync("icons.file", permission: "icons") { body in
            Icons.forFile(path: body["path"] as? String ?? "", size: body["size"] as? Int ?? 64)
        },

        // Windows — focused-window helpers operate on the AX focused window
        // of frontmost app. All Bool-returning except byId.frame (returns
        // dict or nil).
        .sync("windows.setFrame",   permission: "windows", denyValue: false) { body in
            Windows.setFocusedFrame(
                x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                w: body["w"] as? Double ?? 0, h: body["h"] as? Double ?? 0)
        },
        .sync("windows.minimize",   permission: "windows", denyValue: false) { body in Windows.minimizeFocused(body["value"] as? Bool ?? true) },
        .sync("windows.fullscreen", permission: "windows", denyValue: false) { body in Windows.fullscreenFocused(body["value"] as? Bool ?? true) },
        .sync("windows.raise",      permission: "windows", denyValue: false) { _    in Windows.raiseFocused() },

        // Windows-by-id
        .sync("windows.byId.setFrame",   permission: "windows", denyValue: false) { body in
            WindowsByID.setFrame(
                windowID: CGWindowID((body["id"] as? Int) ?? 0),
                x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                w: body["w"] as? Double ?? 0, h: body["h"] as? Double ?? 0)
        },
        .sync("windows.byId.minimize",   permission: "windows", denyValue: false) { body in WindowsByID.minimize(  windowID: CGWindowID((body["id"] as? Int) ?? 0), body["value"] as? Bool ?? true) },
        .sync("windows.byId.fullscreen", permission: "windows", denyValue: false) { body in WindowsByID.fullscreen(windowID: CGWindowID((body["id"] as? Int) ?? 0), body["value"] as? Bool ?? true) },
        .sync("windows.byId.raise",      permission: "windows", denyValue: false) { body in WindowsByID.raise(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
        .sync("windows.byId.focus",      permission: "windows", denyValue: false) { body in WindowsByID.focus(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
        .sync("windows.byId.close",      permission: "windows", denyValue: false) { body in WindowsByID.close(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
        .sync("windows.byId.frame",      permission: "windows") { body in
            guard let r = WindowsByID.frame(windowID: CGWindowID((body["id"] as? Int) ?? 0)) else { return nil }
            return [
                "x": Int(r.origin.x), "y": Int(r.origin.y),
                "w": Int(r.size.width), "h": Int(r.size.height)
            ] as [String: Any]
        },

        // Spaces — returns array; pre-refactor returned `[]` on deny.
        .sync("spaces.windowSpaces", permission: "spaces", denyValue: [NSNumber]()) { body in
            Spaces.windowSpaces(windowID: UInt32((body["id"] as? Int) ?? 0)).map { NSNumber(value: $0) }
        },

        // Accessibility — all .ax variants hop to main and have access to axHandles via bridge
        .ax("ax.focused") { _, _ in AX.focusedElement() },
        .ax("ax.application")             { b, body in AX.application(pid: pid_t((body["pid"] as? Int) ?? 0), store: b.axHandles) },
        .ax("ax.system")                  { b, _    in AX.systemWide(store: b.axHandles) },
        .ax("ax.systemElementAtPosition") { b, body in AX.systemElementAtPosition(x: Float((body["x"] as? Double) ?? 0), y: Float((body["y"] as? Double) ?? 0), store: b.axHandles) },
        .ax("ax.focusedElement")          { b, _    in AX.focusedElementHandle(store: b.axHandles) },
        .ax("ax.attributeNames")          { b, body in AX.attributeNames(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
        .ax("ax.attribute")               { b, body in AX.attribute(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", store: b.axHandles) },
        .ax("ax.attributes")              { b, body in AX.attributes(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
        .ax("ax.parameterizedAttributeNames") { b, body in AX.parameterizedAttributeNames(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
        .ax("ax.parameterizedAttribute")  { b, body in AX.parameterizedAttribute(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", param: body["param"], store: b.axHandles) },
        .ax("ax.actionNames")             { b, body in AX.actionNames(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
        .ax("ax.isAttributeSettable")     { b, body in AX.isAttributeSettable(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", store: b.axHandles) },
        .ax("ax.setAttribute", denyValue: false) { b, body in AX.setAttribute(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", value: body["value"], store: b.axHandles) },
        .ax("ax.performAction", denyValue: false) { b, body in AX.performAction(handle: (body["handle"] as? Int) ?? -1, action: body["action"] as? String ?? "", store: b.axHandles) },
        .ax("ax.children")                { b, body in AX.children(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
        .ax("ax.parent")                  { b, body in AX.parent(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
        .ax("ax.role")                    { b, body in AX.role(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
        // release / releaseAll have no permission gate — releasing a handle is
        // always safe regardless of the original "ax" permission state.
        .ax("ax.release",    permission: nil) { b, body in b.axHandles.release((body["handle"] as? Int) ?? -1) },
        .ax("ax.releaseAll", permission: nil) { b, _    in b.axHandles.releaseAll(); return true },

        // Invocable-window control — async (must hop to main for AppKit).
        .custom("window.invoke", denyValue: false) { bridge, _, requestId in
            DispatchQueue.main.async { [weak bridge] in
                if let win = bridge?.webView?.window as? StackWindow, win.invocable {
                    win.invoke()
                    bridge?.respond(requestId: requestId, value: true)
                } else {
                    bridge?.respond(requestId: requestId, value: false)
                }
            }
        },
        .custom("window.dismiss", denyValue: false) { bridge, _, requestId in
            DispatchQueue.main.async { [weak bridge] in
                if let win = bridge?.webView?.window as? StackWindow, win.invocable {
                    win.dismiss()
                    bridge?.respond(requestId: requestId, value: true)
                } else {
                    bridge?.respond(requestId: requestId, value: false)
                }
            }
        },

        // Native popup menu — async (resolves on user pick / cancel).
        .custom("menu.popup", permission: "menu") { bridge, body, requestId in
            let items = body["items"] as? [[String: Any]] ?? []
            PopupMenu.present(items: items) { [weak bridge] picked in
                bridge?.respond(requestId: requestId, value: picked as Any? ?? NSNull())
            }
        },

        // ── Menubar items (NSStatusItem) ─────────────────────────────────────
        // addItem mints an id, creates the NSStatusItem on main, wires click /
        // menu-pick callbacks back to JS via __sd_menubar_event. Per-stack
        // scope removes orphans on unload. New permission: "menubar.item",
        // distinct from "menubar" (which gates suppress/restore).
        .custom("menubar.addItem", permission: "menubar.item") { bridge, body, requestId in
            DispatchQueue.main.async { [weak bridge] in
                guard let bridge = bridge else { return }
                let id = bridge.nextStatusItemId
                bridge.nextStatusItemId += 1
                let spec = Bridge.parseStatusItemSpec(body)
                let handle = Menubar.addItem(id: id, spec: spec)
                handle.onClick = { [weak bridge] in
                    bridge?.dispatchMenubarEvent(itemId: id, type: "click", payload: nil)
                }
                handle.onMenuPick = { [weak bridge] pickId in
                    bridge?.dispatchMenubarEvent(itemId: id, type: "pick", payload: pickId)
                }
                bridge.statusItems[id] = handle
                bridge.respond(requestId: requestId, value: id)
            }
        },
        .syncBridge("menubar.item.setTitle", permission: "menubar.item", denyValue: false) { b, body in
            guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
            h.setTitle(body["title"] as? String)
            return true
        },
        .syncBridge("menubar.item.setIcon", permission: "menubar.item", denyValue: false) { b, body in
            guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
            let iconDict = body["icon"] as? [String: Any]
            h.setIcon(iconDict.map(Bridge.parseIconSpec))
            return true
        },
        .syncBridge("menubar.item.setMenu", permission: "menubar.item", denyValue: false) { b, body in
            guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
            h.setMenu(body["items"] as? [[String: Any]])
            return true
        },
        .syncBridge("menubar.item.setTooltip", permission: "menubar.item", denyValue: false) { b, body in
            guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
            h.setTooltip(body["tooltip"] as? String)
            return true
        },
        .syncBridge("menubar.item.remove", permission: "menubar.item", denyValue: false) { b, body in
            guard let id = body["id"] as? Int, let h = b.statusItems.removeValue(forKey: id) else { return false }
            h.remove()
            return true
        },

        // ── Dynamic hotkey bind/unbind from JS ───────────────────────────────
        // Static manifest hotkeys cover the common case; this lets palettes /
        // modal stacks register transient chords on demand (Palette verb mode,
        // ChoiceBox, ForceKeys). Returns the id on success, null on parse error.
        // Gated on "hotkey" permission so dynamic registration is auditable
        // (manifest hotkeys are already inspectable in stack.json).
        .custom("hotkey.bind", permission: "hotkey") { bridge, body, requestId in
            guard let spec = body["spec"] as? String else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            let id = bridge.nextHotkeyId
            bridge.nextHotkeyId += 1
            let token = HotkeyRegistry.shared.bind(spec: spec) { [weak bridge] in
                // Fire on the same hop pattern as fireBang / fireHotkey — the
                // Carbon callback already runs on main, but the eval has to be
                // async to keep main from re-entering JS while a script is mid-flight.
                guard let webView = bridge?.webView else { return }
                DispatchQueue.main.async {
                    webView.evaluateJavaScript("window.__sd_hotkey_fire && window.__sd_hotkey_fire(\(id));",
                                               completionHandler: nil)
                }
            }
            guard let token = token else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            bridge.hotkeyTokens[id] = token
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("hotkey.unbind", permission: "hotkey", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let token = b.hotkeyTokens.removeValue(forKey: id) else { return false }
            token.cancel()
            return true
        },

        // ── Generic NSDistributedNotificationCenter observer ─────────────────
        // Complements Caffeinate (which hard-codes screenIsLocked / screenIsUnlocked):
        // here the stack picks the notification name. Same mint-id + window-global
        // fire pattern as hotkey.bind. Permission: "distributednotifications".
        .custom("dn.observe", permission: "distributednotifications") { bridge, body, requestId in
            guard let name = body["name"] as? String else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            let id = bridge.nextDnId
            bridge.nextDnId += 1
            let token = DistributedNotifications.observe(name: name) { [weak bridge] payload in
                guard let webView = bridge?.webView else { return }
                let json = Bridge.jsonify(payload)
                DispatchQueue.main.async {
                    webView.evaluateJavaScript("window.__sd_dn_fire && window.__sd_dn_fire(\(id), \(json));",
                                               completionHandler: nil)
                }
            }
            bridge.dnTokens[id] = token
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("dn.unobserve", permission: "distributednotifications", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t = b.dnTokens.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },

        // Stack-to-stack bang — async fan-out via StackHost.
        .custom("bang") { bridge, body, requestId in
            guard let name = body["name"] as? String else {
                bridge.respond(requestId: requestId, value: 0); return
            }
            let detail = (body["detail"] as? [String: Any]) ?? [:]
            DispatchQueue.main.async { [weak bridge] in
                let fired = AppDelegate.shared?.host?.bang(name: name, detail: detail) ?? 0
                bridge?.respond(requestId: requestId, value: fired)
            }
        }
    ]

    private static let dispatch: [String: Primitive] =
        Dictionary(uniqueKeysWithValues: primitives.map { ($0.type, $0) })

    private func dispatchFsEvents(watchId: Int, events: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard let webView = webView else { return }
        let payload = events.map { ev -> [String: Any] in
            ["path": ev.path, "kind": FSWatch.kindFor(flags: ev.flags)]
        }
        let json = Bridge.jsonify(payload)
        let script = "window.__sd_fs_event && window.__sd_fs_event(\(watchId), \(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    /// Pump a menubar-item click / pick / etc. back to JS. The JS-side proxy
    /// in api.js (sd.menubar.addItem) routes this to the stack's callbacks.
    fileprivate func dispatchMenubarEvent(itemId: Int, type: String, payload: Any?) {
        guard let webView = webView else { return }
        let payloadJson = payload.map { Bridge.jsonify($0) } ?? "null"
        let script = "window.__sd_menubar_event && window.__sd_menubar_event(\(itemId), \"\(type)\", \(payloadJson));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("stackd: \(s)\n".utf8))
    }

    private func replayState() {
        if permissions.contains("battery"), let json = lastBattery {
            push(channel: "battery", json: json)
        }
        if permissions.contains("mouse"), let json = lastMouse {
            push(channel: "mouse", json: json)
        }
        if permissions.contains("app"), let json = lastFrontApp {
            push(channel: "frontApp", json: json)
        }
        if permissions.contains("windows"), let json = lastFocusedWindow {
            push(channel: "focusedWindow", json: json)
        }
        if permissions.contains("windows"), let json = lastWindowsAll {
            push(channel: "windowsAll", json: json)
        }
        if permissions.contains("appearance"), let json = lastAppearance {
            push(channel: "appearance", json: json)
        }
        if permissions.contains("input"), let json = lastInput {
            push(channel: "inputLayout", json: json)
        }
        if permissions.contains("net") {
            if let json = lastNetWifi { push(channel: "netWifi", json: json) }
            if let json = lastNetLan  { push(channel: "netLan",  json: json) }
        }
        if permissions.contains("audio"), let json = lastAudio {
            push(channel: "audioOutput", json: json)
        }
        if permissions.contains("display"), let json = lastDisplay {
            push(channel: "displays", json: json)
        }
        if permissions.contains("media"), let json = lastMedia {
            push(channel: "media", json: json)
        }
        if permissions.contains("pasteboard"), let json = lastPasteboard {
            push(channel: "pasteboard", json: json)
        }
        if permissions.contains("apps"), let json = lastApps {
            push(channel: "apps", json: json)
        }
        if permissions.contains("spaces"), let json = lastSpaces {
            push(channel: "spaces", json: json)
        }
        if permissions.contains("caffeinate"), let json = lastCaffeinate {
            push(channel: "caffeinate", json: json)
        }
        if permissions.contains("location"), let json = lastLocation {
            push(channel: "location", json: json)
        }
        if permissions.contains("usb"), let json = lastUSB {
            push(channel: "usb", json: json)
        }
        if permissions.contains("camera"), let json = lastCamera {
            push(channel: "camera", json: json)
        }
    }

    private func startBattery() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let pct = Battery.percent()
            let charging = Battery.isCharging()
            let json = "{\"percent\":\(pct),\"charging\":\(charging)}"
            if json == self.lastBattery { return }     // skip no-op push
            self.lastBattery = json
            self.push(channel: "battery", json: json)
        }
        pushFn()
        scope.adopt(BatteryObserver.shared.subscribe(pushFn))
    }

    private func startMouse() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let p = Mouse.location()
            let json = "{\"x\":\(Int(p.x)),\"y\":\(Int(p.y))}"
            if json == self.lastMouse { return }       // idle cursor → no push
            self.lastMouse = json
            self.push(channel: "mouse", json: json)
        }
        pushFn()
        scope.adopt(MouseObserver.shared.subscribe(pushFn))
    }

    private func startAppearance() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Appearance.current())
            if json == self.lastAppearance { return }
            self.lastAppearance = json
            self.push(channel: "appearance", json: json)
        }
        pushFn()
        scope.adopt(AppearanceObserver.shared.subscribe(pushFn))
    }

    private func startInput() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Input.currentLayout())
            if json == self.lastInput { return }
            self.lastInput = json
            self.push(channel: "inputLayout", json: json)
        }
        pushFn()
        scope.adopt(InputObserver.shared.subscribe(pushFn))
    }

    private func startNetwork() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let lanJson = Bridge.jsonify(NetLAN.current())
            if lanJson != self.lastNetLan {
                self.lastNetLan = lanJson
                self.push(channel: "netLan", json: lanJson)
            }
            let wifiJson = Bridge.jsonify(NetWiFi.current())
            if wifiJson != self.lastNetWifi {
                self.lastNetWifi = wifiJson
                self.push(channel: "netWifi", json: wifiJson)
            }
        }
        pushFn()
        scope.adopt(NetworkObserver.shared.subscribe(pushFn))
    }

    private func startAudio() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Audio.current())
            if json == self.lastAudio { return }
            self.lastAudio = json
            self.push(channel: "audioOutput", json: json)
        }
        pushFn()
        scope.adopt(AudioObserver.shared.subscribe(pushFn))
    }

    private func startDisplay() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Display.all())
            if json == self.lastDisplay { return }
            self.lastDisplay = json
            self.push(channel: "displays", json: json)
        }
        pushFn()
        scope.adopt(DisplayObserver.shared.subscribe(pushFn))
    }

    private func startMedia() {
        let pushFn: () -> Void = { [weak self] in
            Media.nowPlaying { info in
                guard let self = self else { return }
                let json = info.map { Bridge.jsonify($0) } ?? "null"
                DispatchQueue.main.async {
                    if json == self.lastMedia { return }
                    self.lastMedia = json
                    self.push(channel: "media", json: json)
                }
            }
        }
        pushFn()
        scope.adopt(MediaObserver.shared.subscribe(pushFn))
    }

    private func startPasteboard() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            // The signal payload is the current string (or null) — that's what
            // every consumer (CloudPad URL copy, Palette clipboard verbs,
            // Muse paste-at-caret) actually wants.
            let s = Pasteboard.getString() ?? ""
            let json = Bridge.jsonify(["text": s, "changeCount": Pasteboard.changeCount])
            if json == self.lastPasteboard { return }
            self.lastPasteboard = json
            self.push(channel: "pasteboard", json: json)
        }
        pushFn()
        scope.adopt(PasteboardObserver.shared.subscribe(pushFn))
    }

    private func startApps() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let snapshot = Apps.running()
            let json = Bridge.jsonify(snapshot)
            if json == self.lastApps { return }

            // Compute delta vs last snapshot before updating cache. Consumers
            // that only care about transitions (apptimeout, notunes) subscribe
            // to "appsChanged" instead of iterating the full list every tick.
            // WebKit GPU + Networking helpers share their bundleId across
            // every WKWebView (one process per stack). Dictionary(uniqueKeysWithValues:)
            // crashes on duplicate keys, so accept last-wins — the delta cares
            // about transitions, not which specific PID landed.
            var nowByBundle: [String: [String: Any]] = [:]
            for app in snapshot {
                if let bid = app["bundleId"] as? String { nowByBundle[bid] = app }
            }
            var added:   [[String: Any]] = []
            var removed: [[String: Any]] = []
            var changed: [[String: Any]] = []
            for (bid, app) in nowByBundle {
                if let prev = self.lastAppsByBundle[bid] {
                    // Compare only the mutable fields. NSRunningApplication
                    // surfaces active/hidden as the only things that flip
                    // during a process's lifetime; name occasionally changes
                    // on localization switches. Avoid jsonify() comparison
                    // because Swift dict-key ordering is non-deterministic
                    // and would fire "changed" on every poll for free.
                    let a1 = (prev["active"] as? Bool) ?? false
                    let a2 = (app["active"]  as? Bool) ?? false
                    let h1 = (prev["hidden"] as? Bool) ?? false
                    let h2 = (app["hidden"]  as? Bool) ?? false
                    let n1 = (prev["name"]   as? String) ?? ""
                    let n2 = (app["name"]    as? String) ?? ""
                    if a1 != a2 || h1 != h2 || n1 != n2 {
                        changed.append(app)
                    }
                } else {
                    added.append(app)
                }
            }
            for (bid, app) in self.lastAppsByBundle where nowByBundle[bid] == nil {
                removed.append(app)
            }
            self.lastAppsByBundle = nowByBundle
            self.lastApps = json
            self.push(channel: "apps", json: json)
            // Only emit a non-empty delta — first-tick "every app added" is
            // noise (consumers already get the same data on sd.apps.running).
            if !added.isEmpty || !removed.isEmpty || !changed.isEmpty {
                let delta: [String: Any] = [
                    "added":   added,
                    "removed": removed,
                    "changed": changed
                ]
                self.push(channel: "appsChanged", json: Bridge.jsonify(delta))
            }
        }
        pushFn()
        scope.adopt(AppsObserver.shared.subscribe(pushFn))
    }

    private func startSpaces() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Spaces.all())
            if json == self.lastSpaces { return }
            self.lastSpaces = json
            self.push(channel: "spaces", json: json)
        }
        pushFn()
        scope.adopt(SpacesObserver.shared.subscribe(pushFn))
    }

    private func startCaffeinate() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Caffeinate.snapshot())
            if json == self.lastCaffeinate { return }
            self.lastCaffeinate = json
            self.push(channel: "caffeinate", json: json)
        }
        pushFn()
        scope.adopt(CaffeinateObserver.shared.subscribe(pushFn))
    }

    private func startLocation() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            // snapshot() is nil until authorization + first fix; serialize
            // explicitly as "null" so the JS channel sees that initial state.
            let json = Location.snapshot().map(Bridge.jsonify) ?? "null"
            if json == self.lastLocation { return }
            self.lastLocation = json
            self.push(channel: "location", json: json)
        }
        pushFn()
        scope.adopt(LocationObserver.shared.subscribe(pushFn))
    }

    private func startUSB() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(USB.snapshot())
            if json == self.lastUSB { return }
            self.lastUSB = json
            self.push(channel: "usb", json: json)
        }
        pushFn()
        scope.adopt(USBObserver.shared.subscribe(pushFn))
    }

    private func startCamera() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Camera.snapshot())
            if json == self.lastCamera { return }
            self.lastCamera = json
            self.push(channel: "camera", json: json)
        }
        pushFn()
        scope.adopt(CameraObserver.shared.subscribe(pushFn))
    }

    // App activations come from NSWorkspace; within-app focus / title changes
    // come from a per-pid AXObserver (FrontmostWindowObserver) that rebinds
    // on each NSWorkspace.didActivateApplicationNotification. No polling.
    private func startWorkspace(includeApp: Bool, includeWindows: Bool) {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            if includeApp, let app = Workspace.frontmostApp() {
                let json = Bridge.jsonify(app)
                if json != self.lastFrontApp {
                    self.lastFrontApp = json
                    self.push(channel: "frontApp", json: json)
                }
            }
            if includeWindows {
                let json = Windows.focused().map(Bridge.jsonify) ?? "null"
                if json != self.lastFocusedWindow {
                    self.lastFocusedWindow = json
                    self.push(channel: "focusedWindow", json: json)
                }
                let allJson = Bridge.jsonify(Windows.all())
                if allJson != self.lastWindowsAll {
                    self.lastWindowsAll = allJson
                    self.push(channel: "windowsAll", json: allJson)
                }
            }
        }
        pushFn()
        scope.adopt(WorkspaceObserver.shared.subscribe(pushFn))
        if includeWindows {
            scope.adopt(FrontmostWindowObserver.shared.subscribe(pushFn))
        }
    }

    private func fireHotkey(callback: String) {
        guard let webView = webView else { return }
        let safe = callback.replacingOccurrences(of: "\"", with: "")
        let script = "window.onHotkey_\(safe) && window.onHotkey_\(safe)();"
        DispatchQueue.main.async { webView.evaluateJavaScript(script, completionHandler: nil) }
    }

    private func fireEventTap(callback: String, type: CGEventType, event: CGEvent) {
        guard let webView = webView else { return }
        let typeName = EventTapRegistry.name(for: type)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let loc = event.location

        var payload: [String: Any] = [
            "type":     typeName,
            "keyCode":  keyCode,
            "flags":    flags,
            "x":        Int(loc.x),
            "y":        Int(loc.y)
        ]
        if type.rawValue == Gesture.cgEventType.rawValue,
           let g = Gesture.describe(cgEvent: event) {
            for (k, v) in g { payload[k] = v }
        }

        let json = Bridge.jsonify(payload)
        let script = "window.onTap_\(callback) && window.onTap_\(callback)(\(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func push(channel: String, json: String) {
        guard let webView = webView else { return }
        let script = "window.__sd_push && window.__sd_push(\"\(channel)\", \(json));"
        DispatchQueue.main.async { webView.evaluateJavaScript(script, completionHandler: nil) }
    }

    fileprivate static func parseIconSpec(_ dict: [String: Any]) -> IconSpec {
        IconSpec(
            sfSymbol:  dict["sfSymbol"]  as? String,
            pngBase64: dict["pngBase64"] as? String,
            template:  dict["template"]  as? Bool ?? true
        )
    }

    fileprivate static func parseStatusItemSpec(_ body: [String: Any]) -> StatusItemSpec {
        var spec = StatusItemSpec()
        if let icon = body["icon"] as? [String: Any] { spec.icon = parseIconSpec(icon) }
        spec.title   = body["title"]   as? String
        spec.menu    = body["menu"]    as? [[String: Any]]
        spec.tooltip = body["tooltip"] as? String
        return spec
    }

    static func jsonify(_ obj: Any) -> String {
        // .fragmentsAllowed lets us serialize bare scalars (Bool/Int/String) at
        // the top level — required for imperative API responses like
        // setVolume → true, defaults.read → "value".
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    deinit {
        // scope.drain() is called by StackHost.unloadStack BEFORE Bridge is
        // dropped. deinit is just a safety net for the never-attached-to-host
        // path and the daemon-shutdown case.
        scope.drain()
        for w in fsWatches.values { w.stop() }
        axHandles.releaseAll()
    }
}
