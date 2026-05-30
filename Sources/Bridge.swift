import WebKit

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var batteryTimer: Timer?
    private var mouseTimer: Timer?
    private var workspaceTimer: Timer?
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
    private var lastSpaces: String?
    private var settings: StackSettings?
    private var fsWatches: [Int: FSWatch] = [:]
    private var handlesBangs: Set<String> = []

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
        if manifest.permissions.contains("app") || manifest.permissions.contains("windows") {
            startWorkspace(includeApp: manifest.permissions.contains("app"),
                           includeWindows: manifest.permissions.contains("windows"))
        }
        if let hks = manifest.hotkeys {
            for hk in hks {
                let cb = hk.callback
                _ = HotkeyRegistry.shared.bind(spec: hk.key) { [weak self] in
                    self?.fireHotkey(callback: cb)
                }
            }
        }
        if let taps = manifest.eventtap {
            for et in taps {
                guard let type = EventTapRegistry.parse(et.event) else {
                    FileHandle.standardError.write(Data("stackd: unknown eventtap type \(et.event)\n".utf8))
                    continue
                }
                let cb = et.callback
                _ = EventTapRegistry.shared.register(eventType: type) { [weak self] event in
                    self?.fireEventTap(callback: cb, type: type, event: event)
                }
            }
        }
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

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "log", let body = message.body as? [String: Any] {
            let level = body["level"] as? String ?? "log"
            let msg = body["msg"] as? String ?? ""
            FileHandle.standardError.write(Data("stackd: js[\(level)] \(msg)\n".utf8))
        } else if message.name == "sd", let body = message.body as? [String: Any] {
            let type = body["type"] as? String ?? ""
            if type == "ready" {
                replayState()
            } else if type == "defaults.read" {
                handleDefaultsRead(body)
            } else if type == "audio.setVolume" {
                handleAudioSetVolume(body)
            } else if type == "audio.setMuted" {
                handleAudioSetMuted(body)
            } else if type == "display.setBrightness" {
                handleDisplaySetBrightness(body)
            } else if type == "menubar.suppress" {
                handleMenubarSuppress(body)
            } else if type == "menubar.restore" {
                handleMenubarRestore(body)
            } else if type == "media.command" {
                handleMediaCommand(body)
            } else if type == "settings.get" {
                handleSettingsGet(body)
            } else if type == "settings.set" {
                handleSettingsSet(body)
            } else if type == "settings.delete" {
                handleSettingsDelete(body)
            } else if type == "settings.all" {
                handleSettingsAll(body)
            } else if type == "fs.read" {
                handleFsRead(body)
            } else if type == "fs.stat" {
                handleFsStat(body)
            } else if type == "fs.list" {
                handleFsList(body)
            } else if type == "fs.watch.start" {
                handleFsWatchStart(body)
            } else if type == "fs.watch.stop" {
                handleFsWatchStop(body)
            } else if type == "pasteboard.get" {
                handlePasteboardGet(body)
            } else if type == "pasteboard.set" {
                handlePasteboardSet(body)
            } else if type == "proc.exec" {
                handleProcExec(body)
            } else if type == "events.type" {
                handleEventsType(body)
            } else if type == "events.key" {
                handleEventsKey(body)
            } else if type == "events.scroll" {
                handleEventsScroll(body)
            } else if type == "events.click" {
                handleEventsClick(body)
            } else if type == "apps.launch" {
                handleAppsLaunch(body)
            } else if type == "apps.focus" {
                handleAppsFocus(body)
            } else if type == "apps.kill" {
                handleAppsKill(body)
            } else if type == "apps.hide" {
                handleAppsHide(body)
            } else if type == "icons.app" {
                handleIconsApp(body)
            } else if type == "icons.file" {
                handleIconsFile(body)
            } else if type == "windows.setFrame" {
                handleWindowsSetFrame(body)
            } else if type == "windows.minimize" {
                handleWindowsMinimize(body)
            } else if type == "windows.fullscreen" {
                handleWindowsFullscreen(body)
            } else if type == "windows.raise" {
                handleWindowsRaise(body)
            } else if type == "ax.focused" {
                handleAxFocused(body)
            } else if type == "window.invoke" {
                handleWindowInvoke(body)
            } else if type == "window.dismiss" {
                handleWindowDismiss(body)
            } else if type == "menu.popup" {
                handleMenuPopup(body)
            }
        }
    }

    /// JSON-encode a value (or "null") and fire window.__sd_response(requestId, value).
    private func respond(requestId: Int, value: Any?) {
        guard let webView = webView else { return }
        let json = value.map { Bridge.jsonify($0) } ?? "null"
        let script = "window.__sd_response && window.__sd_response(\(requestId), \(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func handleDefaultsRead(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("defaults") else {
            log("defaults.read denied (stack lacks 'defaults' permission)")
            respond(requestId: requestId, value: nil)
            return
        }
        let bundleId = body["bundleId"] as? String ?? ""
        let key      = body["key"]      as? String ?? ""
        respond(requestId: requestId, value: Defaults.read(bundleId: bundleId, key: key))
    }

    private func handleAudioSetVolume(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("audio") else {
            log("audio.setVolume denied (stack lacks 'audio' permission)")
            respond(requestId: requestId, value: false)
            return
        }
        let value = (body["value"] as? Double) ?? 0
        respond(requestId: requestId, value: Audio.setVolume(Float(value)))
    }

    private func handleAudioSetMuted(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("audio") else {
            log("audio.setMuted denied (stack lacks 'audio' permission)")
            respond(requestId: requestId, value: false)
            return
        }
        let value = (body["value"] as? Bool) ?? false
        respond(requestId: requestId, value: Audio.setMuted(value))
    }

    private func handleDisplaySetBrightness(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("display") else {
            log("display.setBrightness denied (stack lacks 'display' permission)")
            respond(requestId: requestId, value: false)
            return
        }
        let id    = CGDirectDisplayID((body["displayID"] as? Int) ?? 0)
        let value = (body["value"] as? Double) ?? 0
        respond(requestId: requestId, value: Display.setBrightness(displayID: id, Float(value)))
    }

    private func handleMenubarSuppress(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("menubar") else {
            log("menubar.suppress denied (stack lacks 'menubar' permission)")
            respond(requestId: requestId, value: false)
            return
        }
        respond(requestId: requestId, value: MenuBarVisibility.suppress())
    }

    private func handleMenubarRestore(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("menubar") else {
            log("menubar.restore denied (stack lacks 'menubar' permission)")
            respond(requestId: requestId, value: false)
            return
        }
        respond(requestId: requestId, value: MenuBarVisibility.restore())
    }

    private func handleMediaCommand(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("media") else {
            log("media.command denied (stack lacks 'media' permission)")
            respond(requestId: requestId, value: false)
            return
        }
        let name = body["name"] as? String ?? ""
        respond(requestId: requestId, value: Media.command(name))
    }

    private func handleSettingsGet(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("settings"), let s = settings else {
            respond(requestId: requestId, value: nil)
            return
        }
        let key = body["key"] as? String ?? ""
        respond(requestId: requestId, value: s.get(key))
    }

    private func handleSettingsSet(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("settings"), let s = settings else {
            respond(requestId: requestId, value: false)
            return
        }
        let key = body["key"] as? String ?? ""
        s.set(key, body["value"])
        respond(requestId: requestId, value: true)
    }

    private func handleSettingsDelete(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("settings"), let s = settings else {
            respond(requestId: requestId, value: false)
            return
        }
        let key = body["key"] as? String ?? ""
        s.delete(key)
        respond(requestId: requestId, value: true)
    }

    private func handleSettingsAll(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("settings"), let s = settings else {
            respond(requestId: requestId, value: [String: Any]())
            return
        }
        respond(requestId: requestId, value: s.all())
    }

    private func handleFsRead(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("fs") else { respond(requestId: requestId, value: nil); return }
        let path = body["path"] as? String ?? ""
        respond(requestId: requestId, value: FS.read(path: path))
    }

    private func handleFsStat(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("fs") else { respond(requestId: requestId, value: nil); return }
        let path = body["path"] as? String ?? ""
        respond(requestId: requestId, value: FS.stat(path: path))
    }

    private func handleFsList(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("fs") else { respond(requestId: requestId, value: nil); return }
        let dir = body["dir"] as? String ?? ""
        let hidden = body["hidden"] as? Bool ?? false
        respond(requestId: requestId, value: FS.list(dir: dir, includeHidden: hidden))
    }

    private func handleFsWatchStart(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("fs") else { respond(requestId: requestId, value: false); return }
        let path = body["path"] as? String ?? ""
        let watchId = body["watchId"] as? Int ?? -1
        let watch = FSWatch(paths: [path]) { [weak self] events in
            self?.dispatchFsEvents(watchId: watchId, events: events)
        }
        guard let w = watch else { respond(requestId: requestId, value: false); return }
        fsWatches[watchId] = w
        respond(requestId: requestId, value: true)
    }

    private func handleFsWatchStop(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        let watchId = body["watchId"] as? Int ?? -1
        if let w = fsWatches.removeValue(forKey: watchId) {
            w.stop()
            respond(requestId: requestId, value: true)
        } else {
            respond(requestId: requestId, value: false)
        }
    }

    private func handlePasteboardGet(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("pasteboard") else { respond(requestId: requestId, value: nil); return }
        respond(requestId: requestId, value: Pasteboard.getString())
    }

    private func handlePasteboardSet(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("pasteboard") else { respond(requestId: requestId, value: false); return }
        let s = body["value"] as? String ?? ""
        respond(requestId: requestId, value: Pasteboard.setString(s))
    }

    private func handleProcExec(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("proc") else { respond(requestId: requestId, value: nil); return }
        let cmd = body["cmd"] as? String ?? ""
        let args = body["args"] as? [String] ?? []
        let input = body["input"] as? String
        let timeout = body["timeout"] as? Double
        Proc.exec(cmd: cmd, args: args, input: input, timeoutSeconds: timeout) { [weak self] result in
            self?.respond(requestId: requestId, value: result)
        }
    }

    private func handleEventsType(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("events") else { respond(requestId: requestId, value: false); return }
        EventsSynth.type(body["value"] as? String ?? "")
        respond(requestId: requestId, value: true)
    }

    private func handleEventsKey(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("events") else { respond(requestId: requestId, value: false); return }
        respond(requestId: requestId, value: EventsSynth.key(body["spec"] as? String ?? ""))
    }

    private func handleEventsScroll(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("events") else { respond(requestId: requestId, value: false); return }
        let dx = Int32(body["dx"] as? Int ?? 0)
        let dy = Int32(body["dy"] as? Int ?? 0)
        respond(requestId: requestId, value: EventsSynth.scroll(dx: dx, dy: dy))
    }

    private func handleEventsClick(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("events") else { respond(requestId: requestId, value: false); return }
        let x = body["x"] as? Double ?? 0
        let y = body["y"] as? Double ?? 0
        let button = body["button"] as? String ?? "left"
        respond(requestId: requestId, value: EventsSynth.click(x: x, y: y, button: button))
    }

    private func handleAppsLaunch(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("apps") else { respond(requestId: requestId, value: false); return }
        respond(requestId: requestId, value: Apps.launch(bundleId: body["bundleId"] as? String ?? ""))
    }

    private func handleAppsFocus(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("apps") else { respond(requestId: requestId, value: false); return }
        respond(requestId: requestId, value: Apps.focus(bundleId: body["bundleId"] as? String ?? ""))
    }

    private func handleAppsKill(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("apps") else { respond(requestId: requestId, value: false); return }
        let force = body["force"] as? Bool ?? false
        respond(requestId: requestId, value: Apps.kill(bundleId: body["bundleId"] as? String ?? "", force: force))
    }

    private func handleAppsHide(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("apps") else { respond(requestId: requestId, value: false); return }
        respond(requestId: requestId, value: Apps.hide(bundleId: body["bundleId"] as? String ?? ""))
    }

    private func handleIconsApp(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("icons") else { respond(requestId: requestId, value: nil); return }
        let bundleId = body["bundleId"] as? String ?? ""
        let size = body["size"] as? Int ?? 64
        respond(requestId: requestId, value: Icons.forApp(bundleId: bundleId, size: size))
    }

    private func handleIconsFile(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("icons") else { respond(requestId: requestId, value: nil); return }
        let path = body["path"] as? String ?? ""
        let size = body["size"] as? Int ?? 64
        respond(requestId: requestId, value: Icons.forFile(path: path, size: size))
    }

    private func handleWindowsSetFrame(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("windows") else { respond(requestId: requestId, value: false); return }
        let x = body["x"] as? Double ?? 0
        let y = body["y"] as? Double ?? 0
        let w = body["w"] as? Double ?? 0
        let h = body["h"] as? Double ?? 0
        respond(requestId: requestId, value: Windows.setFocusedFrame(x: x, y: y, w: w, h: h))
    }

    private func handleWindowsMinimize(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("windows") else { respond(requestId: requestId, value: false); return }
        let value = body["value"] as? Bool ?? true
        respond(requestId: requestId, value: Windows.minimizeFocused(value))
    }

    private func handleWindowsFullscreen(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("windows") else { respond(requestId: requestId, value: false); return }
        let value = body["value"] as? Bool ?? true
        respond(requestId: requestId, value: Windows.fullscreenFocused(value))
    }

    private func handleWindowsRaise(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("windows") else { respond(requestId: requestId, value: false); return }
        respond(requestId: requestId, value: Windows.raiseFocused())
    }

    private func handleAxFocused(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("ax") else { respond(requestId: requestId, value: nil); return }
        respond(requestId: requestId, value: AX.focusedElement())
    }

    private func handleWindowInvoke(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        DispatchQueue.main.async { [weak self] in
            if let win = self?.webView?.window as? StackWindow, win.invocable {
                win.invoke()
                self?.respond(requestId: requestId, value: true)
            } else {
                self?.respond(requestId: requestId, value: false)
            }
        }
    }

    private func handleMenuPopup(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        guard permissions.contains("menu") else {
            log("menu.popup denied (stack lacks 'menu' permission)")
            respond(requestId: requestId, value: nil)
            return
        }
        let items = body["items"] as? [[String: Any]] ?? []
        PopupMenu.present(items: items) { [weak self] picked in
            self?.respond(requestId: requestId, value: picked as Any? ?? NSNull())
        }
    }

    private func handleWindowDismiss(_ body: [String: Any]) {
        let requestId = body["requestId"] as? Int ?? -1
        DispatchQueue.main.async { [weak self] in
            if let win = self?.webView?.window as? StackWindow, win.invocable {
                win.dismiss()
                self?.respond(requestId: requestId, value: true)
            } else {
                self?.respond(requestId: requestId, value: false)
            }
        }
    }

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
    }

    private func startBattery() {
        let tick: () -> Void = { [weak self] in
            guard let self = self else { return }
            let pct = Battery.percent()
            let charging = Battery.isCharging()
            let json = "{\"percent\":\(pct),\"charging\":\(charging)}"
            if json == self.lastBattery { return }     // skip no-op push
            self.lastBattery = json
            self.push(channel: "battery", json: json)
        }
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func startMouse() {
        let tick: () -> Void = { [weak self] in
            guard let self = self else { return }
            let p = Mouse.location()
            let json = "{\"x\":\(Int(p.x)),\"y\":\(Int(p.y))}"
            if json == self.lastMouse { return }       // idle cursor → no push
            self.lastMouse = json
            self.push(channel: "mouse", json: json)
        }
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
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
        AppearanceObserver.shared.subscribe(pushFn)
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
        InputObserver.shared.subscribe(pushFn)
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
        NetworkObserver.shared.subscribe(pushFn)
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
        AudioObserver.shared.subscribe(pushFn)
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
        DisplayObserver.shared.subscribe(pushFn)
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
        MediaObserver.shared.subscribe(pushFn)
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
        PasteboardObserver.shared.subscribe(pushFn)
    }

    private func startApps() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Bridge.jsonify(Apps.running())
            if json == self.lastApps { return }
            self.lastApps = json
            self.push(channel: "apps", json: json)
        }
        pushFn()
        AppsObserver.shared.subscribe(pushFn)
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
        SpacesObserver.shared.subscribe(pushFn)
    }

    // App activations come from NSWorkspace; focused window inside an app is AX
    // and changes asynchronously, so a slow tick covers within-app focus changes
    // (Cmd-`, opening a doc) until we install an AXObserver per-app.
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
        WorkspaceObserver.shared.subscribe(pushFn)
        if includeWindows {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in pushFn() }
            RunLoop.main.add(timer, forMode: .common)
            workspaceTimer = timer
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

    static func jsonify(_ obj: Any) -> String {
        // .fragmentsAllowed lets us serialize bare scalars (Bool/Int/String) at
        // the top level — required for imperative API responses like
        // setVolume → true, defaults.read → "value".
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    deinit {
        batteryTimer?.invalidate()
        mouseTimer?.invalidate()
        workspaceTimer?.invalidate()
        for w in fsWatches.values { w.stop() }
    }
}
