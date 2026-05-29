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
        if manifest.permissions.contains("battery") { startBattery() }
        if manifest.permissions.contains("mouse")   { startMouse() }
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
            if type == "ready" { replayState() }
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
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    deinit {
        batteryTimer?.invalidate()
        mouseTimer?.invalidate()
        workspaceTimer?.invalidate()
    }
}
