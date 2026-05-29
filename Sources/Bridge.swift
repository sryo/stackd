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
    private var lastAppearance: String?
    private var lastInput: String?
    private var lastNetWifi: String?
    private var lastNetLan: String?
    private var lastAudio: String?
    private var lastDisplay: String?
    private var lastMedia: String?
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

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        let ucc = webView.configuration.userContentController
        ucc.add(self, name: "sd")
        ucc.add(self, name: "log")
        ucc.addUserScript(Bridge.consoleHookScript)
    }

    func start(manifest: StackManifest) {
        self.permissions = manifest.permissions
        self.handlesBangs = Set(manifest.handles ?? [])
        if manifest.permissions.contains("battery")    { startBattery() }
        if manifest.permissions.contains("mouse")      { startMouse() }
        if manifest.permissions.contains("appearance") { startAppearance() }
        if manifest.permissions.contains("input")      { startInput() }
        if manifest.permissions.contains("net")        { startNetwork() }
        if manifest.permissions.contains("audio")      { startAudio() }
        if manifest.permissions.contains("display")    { startDisplay() }
        if manifest.permissions.contains("media")      { startMedia() }
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

    func fireBang(name: String, detail: [String: String]) {
        guard let webView = webView else { return }
        let safe = name.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "_"
        }
        let suffix = String(safe)
        let pairs = detail.map { (k, v) -> String in
            let sk = k.replacingOccurrences(of: "\"", with: "\\\"")
            let sv = v.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(sk)\":\"\(sv)\""
        }
        let json = "{" + pairs.joined(separator: ",") + "}"
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
    }
}
