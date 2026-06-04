import WebKit
import IOKit.pwr_mgt
import CoreAudio  // AudioDeviceID — used by sd.audio.setDefaultDevice

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    fileprivate var stackId: String = ""
    private var permissions: [String] = []
    // Per-channel JSON dedupe cache, keyed by the channel name used in
    // push(channel:json:). Every startXxx() reads + writes via this dict so
    // adding a new channel doesn't require declaring another `lastXxx` field.
    private var lastState: [String: String] = [:]
    // Parsed snapshot used to compute the sd.apps.changed delta — keyed by
    // bundleId because pids recycle but bundleIds are stable across launches.
    // Not a string cache, so it sits next to lastState rather than inside it.
    private var lastAppsByBundle: [String: [String: Any]] = [:]
    // Same shape for sd.windows.changed — keyed by CGWindowID.
    private var lastWindowsByID: [Int: [String: Any]] = [:]
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
    fileprivate var broadcastTokens: [Int: Token] = [:]
    fileprivate var nextBroadcastId: Int = 1
    // JS-bound URL-scheme handlers: id → Token. Each Token removes this
    // stack's subscriber from the per-scheme SchemeRouter bucket; scope
    // drains them on unload so reloading a stack doesn't accumulate
    // duplicate handlers for the same scheme.
    fileprivate var urlHandlerTokens: [Int: Token] = [:]
    fileprivate var nextURLHandlerId: Int = 1
    // sd.overlay handles: id → (handle, displayLink subscription token).
    // Each handle owns a borderless NSPanel + WKWebView pinned to a foreign
    // target wid; the token drives per-vsync reposition + sd.target push via
    // DisplayLinkObserver. Scope drains both on unload (detach closes the
    // panel, token cancel removes the subscription).
    fileprivate var overlayHandles: [Int: OverlayHandle] = [:]
    fileprivate var overlayTokens: [Int: Token] = [:]
    fileprivate var nextOverlayId: Int = 1
    // Reserved for backpressure if a future overlay tick path becomes async
    // (e.g. snapshot-driven reposition). Currently the tick is synchronous —
    // setFrame + an evaluateJavaScript fire-and-forget — so this stays empty.
    fileprivate var overlayInFlight: Set<Int> = []
    // Owned HTTP servers: serverId → Token (cancel = server.stop()).
    // Pending route requests waiting for sd.httpserver.respond() — keyed
    // by mint id, value is the NWConnection-side completion closure.
    fileprivate var httpServerTokens: [Int: Token] = [:]
    fileprivate var pendingHttpResponses: [Int: (HTTPResponse) -> Void] = [:]
    fileprivate var nextHttpId: Int = 1
    // Bonjour publish + browse handles. Both are long-lived Network.framework
    // primitives; the publish side owns an NWListener, the browse side an
    // NWBrowser. Stack unload drains both via scope (mirrors httpServerTokens).
    // Per-handle channel push for browse uses the synthesized name
    // "bonjour:browse:<id>" — JS sd.bonjour.browse() builds the same name
    // from the returned handle id and subscribes via the standard channel()
    // signal machinery.
    fileprivate var bonjourPublishHandles: [Int: Token] = [:]
    fileprivate var bonjourBrowseHandles: [Int: Token] = [:]
    fileprivate var nextBonjourId: Int = 1
    // Spotlight live-query handles. Each entry owns a Spotlight.LiveQuery
    // (long-lived NSMetadataQuery in continuous-update mode); cancel calls
    // LiveQuery.stop() which tears down the query + its NSNotificationCenter
    // observers. Per-handle channel push uses the synthesized name
    // "spotlight:subscribe:<id>" — JS sd.spotlight.subscribe() builds the
    // same name from the returned handle id and subscribes via the standard
    // channel() signal machinery. Stack unload drains via scope (mirrors
    // bonjourBrowseHandles).
    fileprivate var spotlightLiveHandles: [Int: Token] = [:]
    fileprivate var nextSpotlightLiveId: Int = 1
    // Long-lived sd.camera.stream() handles. Each entry owns a Camera.Stream
    // (AVCaptureSession + sample-buffer delegate) and a Token whose cancel
    // calls stream.stop() — same shape as bonjourBrowseHandles. Per-handle
    // channel push name is "camera:stream:<id>"; JS sd.camera.stream() builds
    // the same name from the returned handle id. Scope drain on stack unload
    // stops every active capture so reload doesn't strand the camera LED on.
    fileprivate var cameraStreamHandles: [Int: Token] = [:]
    fileprivate var nextCameraStreamId: Int = 1
    // sd.speech.listen handles — one Listener per active listen() call. The
    // Listener owns the SFSpeechRecognizer task + AVAudioEngine + tap, so the
    // Token's cancel calls listener.stop() (which removes the tap, cancels
    // the task, ends the request). Per-handle channel push uses the
    // synthesized name "speech:listen:<id>" — JS sd.speech.listen() builds
    // the same name from the returned handle id and subscribes via the
    // standard channel() signal machinery (mirrors bonjour.browse).
    fileprivate var speechListenHandles: [Int: Token] = [:]
    fileprivate var nextSpeechListenId: Int = 1
    // SQLite handles minted via sd.sqlite.open(). Tracked per-Bridge so the
    // scope drain on stack unload closes every connection — the underlying
    // SQLite.HandleStore is process-wide but the *ownership* is stack-scoped.
    fileprivate var sqliteHandles: Set<Int> = []
    // Streamed proc invocations minted via sd.proc.stream(). cancel() sends
    // SIGTERM; the wrapped Process strongly retains the underlying task so
    // the terminationHandler still fires after unload. Scope drain SIGTERMs
    // any still-running child so stack reload doesn't strand subprocesses.
    fileprivate var procStreamHandles: [Int: ProcStreamHandle] = [:]
    fileprivate var nextProcStreamId: Int = 1
    // Active IOPMAssertion handles minted by sd.caffeinate.assert(). Keyed
    // by a per-bridge counter (the id we hand back to JS); value is the raw
    // IOPMAssertionID returned by IOPMAssertionCreateWithName. Released
    // explicitly via sd.caffeinate.release(handleId) — or in bulk by the
    // scope drain on stack unload (so a forgotten wake-lock doesn't outlive
    // the stack that took it).
    fileprivate var caffeinateAssertions: [Int: IOPMAssertionID] = [:]
    fileprivate var nextCaffeinateId: Int = 1
    // Per-channel JS-requested fanout cadence (seconds). Set via the
    // sd.channel.setInterval IPC when a stack calls e.g.
    // `sd.sensors.subscribe(fn, { interval: 5 })`. Channels not listed here
    // fall back to firing on every native observer tick (2s for sensors /
    // host.load / display.all, faster for event-driven observers). The
    // native observer's polling rate isn't changed — we just gate the
    // bridge's fanout, which dominates the per-stack cost (jsonify +
    // evaluateJavaScript). Multiple subscribe(fn, {interval}) calls in the
    // same stack take last-write-wins; stacks coordinate intervals at the
    // module that owns the channel. Currently honored by sensors / hostLoad /
    // displays — the three channels with a fixed-cadence poll. Event-driven
    // channels (mouse, frontApp, audio, …) ignore the gate.
    fileprivate var channelIntervals: [String: TimeInterval] = [:]
    fileprivate var lastChannelPushedAt: [String: Date] = [:]
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

    // Auto-load the sd.* runtime so stacks can be just HTML — no
    // `<script type="module">import "sd://runtime/api.js"</script>` boilerplate
    // required. Stacks that explicitly import the runtime still work: dynamic
    // import resolves to the same module record by URL, so the module body
    // runs once regardless. Dispatched at document end so the runtime can walk
    // the parsed DOM for `{{ }}` template placeholders.
    private static let runtimeLoaderScript: WKUserScript = {
        let source = """
        import("sd://runtime/api.js").catch(e => {
          try { console.error("[stackd] runtime load failed:", String(e)); } catch (_) {}
        });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }()

    /// Minimal CSS reset injected by default. `:where()` gives every selector
    /// inside zero specificity so any stack rule (specificity ≥ (0,0,1)) wins
    /// without authors having to override or know about cascade order. Authors
    /// opt out via `"reset": false` in the manifest when they want full
    /// control of the root box.
    static let resetStyle = ":where(html,body){margin:0;padding:0;background:transparent}"

    init(webView: WKWebView, screen: NSScreen? = nil, screenIndex: Int = 0, padding: Double = 0, injectReset: Bool = true) {
        self.webView = webView
        super.init()
        let ucc = webView.configuration.userContentController
        ucc.add(self, name: "sd")
        ucc.add(self, name: "log")
        ucc.addUserScript(Bridge.consoleHookScript)
        ucc.addUserScript(Bridge.runtimeLoaderScript)
        // Per-instance window.__sd_screen so items like spacenum + brightness
        // can target the screen they're rendered on. Injected at document
        // start so it's visible before any module script runs.
        if let scr = screen {
            let payload = Bridge.jsonify(Bridge.screenInfo(screen: scr, index: screenIndex))
            let source = "window.__sd_screen = \(payload);"
            let inject = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            ucc.addUserScript(inject)
        }
        // Padding via CSS — content-layer spacing that pushes HTML inward
        // from the glass edge, mirroring SwiftUI's `.padding().glassEffect()`
        // pattern. Sets a `--sd-padding` custom property for stacks that
        // want to reference it (gap, child padding, etc.) and applies a
        // default `body { padding: var(--sd-padding); box-sizing: border-box }`
        // so the default look gets the inset for free. Stacks that already
        // own their body padding can override via their own CSS — last
        // declaration wins.
        //
        // Note: this REPLACES the previous geometric WebView-inset approach,
        // which was invisible because both the rim and the WebView showed
        // the same glass through the transparent body. Content-layer padding
        // produces visible space because the HTML doesn't draw there.
        if padding > 0 {
            let style = """
            :root{--sd-padding:\(padding)px;}
            body{padding:var(--sd-padding);box-sizing:border-box;}
            """
            let source = """
            (function(){
              var s = document.createElement('style');
              s.setAttribute('data-sd', 'padding');
              s.textContent = \(Bridge.jsonify(style));
              (document.head || document.documentElement).appendChild(s);
            })();
            """
            // .atDocumentEnd so our <style> appends AFTER the stack's own
            // <link rel="stylesheet"> elements. CSS cascade resolves on
            // declaration order at equal specificity — last wins — so this
            // ensures the daemon-injected padding overrides a stack's own
            // `body { padding: 0 }`. Stacks that want zero padding can opt
            // out via the manifest (`"padding": 0`) instead of fighting the
            // cascade.
            let inject = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            ucc.addUserScript(inject)
        }
        // CSS reset — wraps every rule in `:where()` so specificity is (0,0,0)
        // and any stack rule wins naturally. Opposite cascade story from the
        // padding block above on purpose: the reset is a sensible default the
        // stack should easily override, not a daemon-owned setting like padding.
        if injectReset {
            let source = """
            (function(){
              var s = document.createElement('style');
              s.setAttribute('data-sd', 'reset');
              s.textContent = \(Bridge.jsonify(Bridge.resetStyle));
              (document.head || document.documentElement).appendChild(s);
            })();
            """
            let inject = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            ucc.addUserScript(inject)
        }
    }

    static func screenInfo(screen: NSScreen, index: Int) -> [String: Any] {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let uuid: String = {
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
            return CFUUIDCreateString(nil, cf) as String? ?? ""
        }()
        // Notch geometry: NSScreen exposes auxiliaryTopLeftArea /
        // auxiliaryTopRightArea on notched displays (macOS 12+). Width of
        // the notch = rightArea.origin.x - leftArea.size.width. On
        // external/non-notched displays both are nil; we return null so
        // stacks can branch on it.
        var notchPayload: Any = NSNull()
        if #available(macOS 12.0, *) {
            if let lArea = screen.auxiliaryTopLeftArea,
               let rArea = screen.auxiliaryTopRightArea,
               lArea.width > 0, rArea.origin.x > lArea.width {
                notchPayload = [
                    "leftWidth":  Int(lArea.width),
                    "rightX":     Int(rArea.origin.x),
                    "width":      Int(rArea.origin.x - lArea.width),
                    "safeAreaTop": Int(screen.safeAreaInsets.top)
                ] as [String: Any]
            }
        }
        // Top-left, matching sd.display.all and every other xy in sd.*.
        let cgFrame = CGDisplayBounds(id)
        let nsFrame = screen.frame, nsVisible = screen.visibleFrame
        let topInset    = max(0, nsFrame.maxY - nsVisible.maxY)
        let bottomInset = max(0, nsVisible.minY - nsFrame.minY)
        let leftInset   = max(0, nsVisible.minX - nsFrame.minX)
        let rightInset  = max(0, nsFrame.maxX - nsVisible.maxX)
        let cgVisible = CGRect(
            x: cgFrame.minX + leftInset,
            y: cgFrame.minY + topInset,
            width:  max(0, cgFrame.width  - leftInset - rightInset),
            height: max(0, cgFrame.height - topInset  - bottomInset)
        )
        return [
            "uuid":         uuid,
            "displayID":    Int(id),
            "index":        index,
            "frame":        rect(cgFrame),
            "visibleFrame": rect(cgVisible),
            "notch":        notchPayload
        ]
    }

    private static func rect(_ r: CGRect) -> [String: Int] {
        ["x": Int(r.origin.x), "y": Int(r.origin.y),
         "w": Int(r.size.width), "h": Int(r.size.height)]
    }

    fileprivate static func buildPredicate(_ raw: StackManifest.EventTap.Predicate?) -> EventTapPredicate {
        var p = EventTapPredicate()
        guard let raw = raw else { return p }
        var codes = Set<Int64>()
        if let kc = raw.keyCode { codes.insert(Int64(kc)) }
        if let arr = raw.keyCodes { for k in arr { codes.insert(Int64(k)) } }
        if !codes.isEmpty { p.keyCodes = codes }
        p.flagsMask = raw.flagsMask
        p.flagsAny  = raw.flagsAny
        return p
    }

    func start(manifest: StackManifest) {
        self.stackId = manifest.id
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
        if manifest.permissions.contains("net")        { startNetwork(); startNetworkThroughput() }
        if manifest.permissions.contains("audio")      { startAudio() }
        if manifest.permissions.contains("display")    { startDisplay() }
        if manifest.permissions.contains("media")      { startMedia() }
        if manifest.permissions.contains("calendar")   { startCalendar() }
        if manifest.permissions.contains("privacy")    { startPrivacy() }
        if manifest.permissions.contains("pasteboard") { startPasteboard() }
        if manifest.permissions.contains("apps")       { startApps() }
        if manifest.permissions.contains("spaces")     { startSpaces() }
        if manifest.permissions.contains("caffeinate") { startCaffeinate() }
        if manifest.permissions.contains("sensors")    { startSensors() }
        if manifest.permissions.contains("location")   { startLocation() }
        if manifest.permissions.contains("usb")        { startUSB() }
        if manifest.permissions.contains("camera")     { startCamera() }
        if manifest.permissions.contains("host")       { startHost() }
        if manifest.permissions.contains("touchdevice") { startTouchDevice() }
        if manifest.permissions.contains("displayLink") { startDisplayLink() }
        if manifest.permissions.contains("app") || manifest.permissions.contains("windows") {
            startWorkspace(includeApp: manifest.permissions.contains("app"),
                           includeWindows: manifest.permissions.contains("windows"))
        }
        if manifest.permissions.contains("menubar") { startMenubarItems() }
        if let hks = manifest.hotkeys {
            for hk in hks {
                let cb = hk.callback
                scope.adopt(HotkeyRegistry.shared.bind(
                    spec: hk.key,
                    mode: hk.mode,
                    apps: hk.apps,
                    excludeApps: hk.excludeApps
                ) { [weak self] in
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
                if et.consume == true {
                    let predicate = Bridge.buildPredicate(et.`if`)
                    let key = "\(manifest.id):\(cb)"
                    // requireRects: install an empty cursor-rect gate before
                    // the consumer can fire, so a consumer with no `if:`
                    // predicate doesn't eat every event of its type during
                    // the boot window where JS hasn't yet called
                    // sd.events.setTapRects. Without this, an unguarded
                    // leftMouseDown consumer swallows every click between
                    // stack load and JS-ready.
                    if et.requireRects == true {
                        EventTapRegistry.shared.setConsumerRects(key: key, rects: [])
                    }
                    let token = EventTapRegistry.shared.registerConsumer(
                        eventType: type,
                        predicate: predicate,
                        key: key
                    ) { [weak self] event in
                        self?.fireEventTap(callback: cb, type: type, event: event)
                    }
                    scope.adopt(token)
                } else {
                    scope.adopt(EventTapRegistry.shared.register(eventType: type) { [weak self] event in
                        self?.fireEventTap(callback: cb, type: type, event: event)
                    })
                }
            }
        }
        // If this stack left a sd.windows.batch open (crashed mid-closure,
        // forgot to await commit), commit-and-clear so the process-global sink
        // doesn't strand. WindowsByID.commitBatch is a no-op when no batch is
        // active, so safe to call unconditionally.
        scope.adopt(Token {
            _ = WindowsByID.commitBatch()
        })
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
            for (_, t) in self.broadcastTokens { t.cancel() }
            self.broadcastTokens.removeAll()
        })
        // Same shape for JS-bound URL-scheme handlers — drop every per-scheme
        // subscriber this stack added to the process-global SchemeRouter so
        // reload-then-register doesn't leak handlers (the NSAppleEventManager
        // slot itself is install-once and stays — SkyLight-style — but the
        // per-scheme fan-out bucket only keeps entries with live subscribers).
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.urlHandlerTokens { t.cancel() }
            self.urlHandlerTokens.removeAll()
        })
        // Caffeinate assertions — IOPMAssertionRelease every wake-lock this
        // stack took. Stacks that forget to release on unload (or crash
        // mid-task) would otherwise hold the assertion until the daemon
        // process exits, which means a forgotten "exporting video" assert
        // can pin the display awake forever.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, id) in self.caffeinateAssertions { Caffeinate.release(id: id) }
            self.caffeinateAssertions.removeAll()
        })
        // HTTP servers — stop every listener owned by this stack and resolve
        // any in-flight requests with 503 so the connection's send-then-cancel
        // path doesn't leak the NWConnection.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.httpServerTokens { t.cancel() }
            self.httpServerTokens.removeAll()
            for (_, complete) in self.pendingHttpResponses {
                complete(HTTPResponse(status: 503, headers: [:], body: "stack unloaded"))
            }
            self.pendingHttpResponses.removeAll()
        })
        // Bonjour — stop every NWListener / NWBrowser owned by this stack
        // so reload doesn't leak advertisements or browse sockets.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.bonjourPublishHandles { t.cancel() }
            self.bonjourPublishHandles.removeAll()
            for (_, t) in self.bonjourBrowseHandles { t.cancel() }
            self.bonjourBrowseHandles.removeAll()
        })
        // Spotlight live queries — stop every continuous-update
        // NSMetadataQuery owned by this stack so reload doesn't leak the
        // backing query objects or their NSNotificationCenter observers.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.spotlightLiveHandles { t.cancel() }
            self.spotlightLiveHandles.removeAll()
        })
        // Camera streams — stop every AVCaptureSession owned by this stack
        // so reload doesn't leave the camera LED on / hold the device.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.cameraStreamHandles { t.cancel() }
            self.cameraStreamHandles.removeAll()
        })
        // Speech listeners — stop every active SFSpeechRecognizer task +
        // audio tap owned by this stack. Without this, a stack that hot-
        // reloads while listening would strand the recognizer holding the
        // microphone (and the recording-indicator dot) until the daemon
        // process exits.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.speechListenHandles { t.cancel() }
            self.speechListenHandles.removeAll()
        })
        // SQLite — sqlite3_close_v2 every connection minted by this stack.
        // No-ops if the JS code already called db.close() explicitly.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for h in self.sqliteHandles { SQLite.close(handle: h) }
            self.sqliteHandles.removeAll()
        })
        // Streamed proc children — SIGTERM any still-running subprocess so
        // stack unload / reload doesn't strand them. The terminationHandler
        // still fires for in-flight cancels; JS callbacks just won't be there
        // to receive the exit event (the bridge is being torn down).
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, h) in self.procStreamHandles { h.cancel() }
            self.procStreamHandles.removeAll()
        })
        // Overlays — cancel each per-overlay displayLink subscription, then
        // detach each handle (closes the overlay NSPanel). Mirrors the
        // statusItems / hotkeyTokens drain shape so a hot-reload doesn't
        // leak panels. NSPanel.close must run on main; we sync-hop
        // (matching the per-call overlay.detach path) so the panels are
        // actually torn down before the new stack instance has a chance
        // to attach its own — otherwise a hot-reload of overlay-border
        // produces two visible outlines until the OS gets around to
        // running the async block.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for (_, t) in self.overlayTokens { t.cancel() }
            self.overlayTokens.removeAll()
            let handles = Array(self.overlayHandles.values)
            self.overlayHandles.removeAll()
            self.overlayInFlight.removeAll()
            if Thread.isMainThread {
                for h in handles { h.detach() }
            } else {
                DispatchQueue.main.sync {
                    for h in handles { h.detach() }
                }
            }
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
        // Trace every primitive call when STACKD_RPC_DEBUG=1. Throttled
        // per (stack, type) pair so a stack that polls every 1s doesn't
        // drown the log. Off by default to keep production logs quiet —
        // ~5 lines/sec at rest under heavy stack load.
        if Bridge.rpcTraceEnabled {
            let rpcKey = "\(stackId)|\(type)"
            let now = Date().timeIntervalSince1970
            let lastLogged = Bridge.lastRpcLogged[rpcKey] ?? 0
            if now - lastLogged >= Bridge.rpcLogThrottleSec {
                Bridge.lastRpcLogged[rpcKey] = now
                FileHandle.standardError.write(Data("stackd: rpc \(stackId) → \(type)\n".utf8))
            }
        }
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

    // Per-(stack, type) throttle table for rpc trace logging. Static because
    // Bridge instances are per-stack; the table key already includes stackId
    // so we don't get cross-stack collisions, and a global table lets the
    // throttle survive stack reloads (avoids a flood right after reload).
    private static var lastRpcLogged: [String: TimeInterval] = [:]
    private static let rpcLogThrottleSec: TimeInterval = 10.0
    private static let rpcTraceEnabled: Bool =
        ProcessInfo.processInfo.environment["STACKD_RPC_DEBUG"] != nil
    // Same throttle for channel pushes (push() below). Per-channel keyed,
    // so first push after a quiet period always prints and high-rate
    // channels like mouse / windows.moved settle into 1 line every N s.
    private static var lastPushLogged: [String: TimeInterval] = [:]
    private static let pushLogThrottleSec: TimeInterval = 5.0

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

        // Host — one-shot system info (hostname / OS / locale / arch / cpu / ram).
        // The 2s CPU+idle+memory signal is the sd.host.load channel pushed
        // by startHost() above.
        .sync("host.info", permission: "host") { _ in Host.info() },

        // Per-disk I/O rates — pulled (not pushed) because the cadence is
        // entirely up to the stack. First call seeds the per-device baseline
        // and returns cumulative byte counts only; second + subsequent calls
        // add bytesReadPerSecond / bytesWrittenPerSecond computed from the
        // delta against the previous sample. Stats.app-style walk of
        // IOBlockStorageDriver nodes — see Host.diskIO() for the IOKit details.
        .sync("host.diskIO", permission: "host", denyValue: [[String: Any]]()) { _ in
            Host.diskIO()
        },

        // Disks — one-shot snapshot of currently-mounted volumes. Live
        // changes flow via `sd.disk.mounted` / `sd.disk.unmounted` bangs
        // (no permission required to receive bangs; install is global).
        .sync("disks.list", permission: "disks", denyValue: [[String: Any]]()) { _ in Disks.list() },

        // Move the cursor without clicking. The missing primitive next to
        // sd.events.click — stacks composing mouse-follows-focus or radial
        // gestures need cursor motion as a first-class action. Gated under
        // "mouse" to match the read side (channel("mouse")).
        .sync("mouse.warp", permission: "mouse", denyValue: false) { body in
            Mouse.warp(x: (body["x"] as? Double) ?? 0, y: (body["y"] as? Double) ?? 0)
        },

        // Audio — Bool side-effect ops, deny → false. Output ops touch the
        // default output device's "virtual main" volume / mute. Input ops
        // mirror the same shape for the default input device (CoreAudio
        // property API only — does NOT open a stream, so the microphone TCC
        // prompt is not triggered).
        .sync("audio.setVolume", permission: "audio", denyValue: false) { body in
            Audio.setVolume(Float((body["value"] as? Double) ?? 0))
        },
        .sync("audio.setMuted", permission: "audio", denyValue: false) { body in
            Audio.setMuted((body["value"] as? Bool) ?? false)
        },
        .sync("audio.setInputVolume", permission: "audio", denyValue: false) { body in
            Audio.setInputVolume(Float((body["value"] as? Double) ?? 0))
        },
        .sync("audio.setInputMuted", permission: "audio", denyValue: false) { body in
            Audio.setInputMuted((body["value"] as? Bool) ?? false)
        },
        // Per-scope device enumeration. Returns [{id, name, manufacturer?,
        // transportType?, uid?, isDefault}, ...] — id is the AudioDeviceID
        // as Int so JS can pass it back through `setDefaultDevice`. Filtered
        // to devices that actually have streams in the requested direction
        // (an output-only device doesn't appear in the input list).
        .sync("audio.devices", permission: "audio", denyValue: [[String: Any]]()) { body in
            let scope: Audio.Scope = (body["scope"] as? String) == "input" ? .input : .output
            return Audio.devices(scope: scope)
        },
        .sync("audio.setDefaultDevice", permission: "audio", denyValue: false) { body in
            guard let id = body["id"] as? Int else { return false }
            let scope: Audio.Scope = (body["scope"] as? String) == "input" ? .input : .output
            return Audio.setDefaultDevice(id: AudioDeviceID(id), scope: scope)
        },

        // Display
        //
        // `displayID` is the CGDirectDisplayID returned by sd.display.all.
        // When 0 / missing, falls back to CGMainDisplayID so single-display
        // callers can just pass the value without enumerating screens.
        // Routing between internal (DisplayServices) and external (DDC/CI
        // via IOAVService) happens inside Display.setBrightness.
        .sync("display.setBrightness", permission: "display", denyValue: false) { body in
            let id: CGDirectDisplayID
            if let raw = body["displayID"] as? Int, raw != 0 {
                id = CGDirectDisplayID(raw)
            } else {
                id = CGMainDisplayID()
            }
            return Display.setBrightness(
                displayID: id,
                Float((body["value"] as? Double) ?? 0))
        },
        // Mirror of setBrightness — reads back current brightness as a 0..1
        // Double or null. External monitors often nil out (DDC-read is
        // optional in the spec); built-in always returns a value.
        .sync("display.getBrightness", permission: "display", denyValue: NSNull()) { body in
            let id: CGDirectDisplayID
            if let raw = body["displayID"] as? Int, raw != 0 {
                id = CGDirectDisplayID(raw)
            } else {
                id = CGMainDisplayID()
            }
            return Display.brightness(of: id).map { Double($0) } ?? NSNull()
        },

        // Display snapshot — single-frame ScreenCaptureKit grab (14+) or
        // CGWindowListCreateImage on 13. Returns { dataURL, width, height }
        // or null on failure. Folded under the existing "display" permission
        // because every consumer that needs pixels already wants sd.display.all
        // to enumerate screens.
        .custom("display.snapshot", permission: "display") { bridge, body, requestId in
            let id = (body["displayID"] as? Int).map { CGDirectDisplayID($0) }
                ?? CGMainDisplayID()
            var region: CGRect? = nil
            if let r = body["region"] as? [String: Any] {
                region = CGRect(
                    x: (r["x"] as? Double) ?? 0,
                    y: (r["y"] as? Double) ?? 0,
                    width:  (r["w"] as? Double) ?? 0,
                    height: (r["h"] as? Double) ?? 0
                )
            }
            let opts = DisplaySnapshot.Options(
                displayID: id,
                region: region,
                format: body["format"] as? String ?? "png",
                quality: body["quality"] as? Double ?? 0.85
            )
            DisplaySnapshot.capture(opts) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
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
        .sync("fs.read", permission: "fs") { body in
            // encoding:
            //   "utf8"   (default) — UTF-8 decoded string, null on non-UTF-8 bytes
            //   "base64" — raw bytes base64-encoded (binary-safe; PNG/plist/etc)
            FS.read(path:     body["path"]     as? String ?? "",
                    encoding: body["encoding"] as? String ?? "utf8")
        },
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

        // Extended attributes (com.apple.metadata:*, Finder tags, quarantine,
        // WhereFroms). get returns the raw bytes base64-encoded — binary plist
        // payloads survive the IPC. No auto-decoding in v1; stacks that want
        // a readable tag list parse the binary plist themselves.
        .sync("fs.xattr.get", permission: "fs") { body in
            Xattr.get(path: body["path"] as? String ?? "",
                      name: body["name"] as? String ?? "")
        },
        .sync("fs.xattr.set", permission: "fs", denyValue: false) { body in
            Xattr.set(path:  body["path"]  as? String ?? "",
                      name:  body["name"]  as? String ?? "",
                      value: body["value"] as? String ?? "")
        },
        .sync("fs.xattr.list", permission: "fs") { body in
            Xattr.list(path: body["path"] as? String ?? "") as Any? ?? NSNull()
        },
        .sync("fs.xattr.remove", permission: "fs", denyValue: false) { body in
            Xattr.remove(path: body["path"] as? String ?? "",
                         name: body["name"] as? String ?? "")
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

        // Sound — NSSound playback. Fire-and-forget; returns true if playback started.
        .sync("sound.system", permission: "sound", denyValue: false) { body in
            Sound.system(body["name"] as? String ?? "")
        },
        .sync("sound.file", permission: "sound", denyValue: false) { body in
            Sound.file(body["path"] as? String ?? "")
        },
        .sync("sound.beep", permission: "sound", denyValue: false) { _ in
            Sound.beep(); return true
        },

        // NaturalLanguage — language ID, tokenization, lemmas, sentence
        // similarity. similarity() returns 0 if the embedding model for the
        // detected language isn't downloaded (English ships by default).
        .sync("nlp.language", permission: "nlp") { body in
            NLP.language(text: body["text"] as? String ?? "") as Any? ?? NSNull()
        },
        .sync("nlp.tokens", permission: "nlp") { body in
            NLP.tokens(text: body["text"] as? String ?? "", unit: body["unit"] as? String ?? "word")
        },
        .sync("nlp.lemmas", permission: "nlp") { body in
            NLP.lemmas(text: body["text"] as? String ?? "")
        },
        .sync("nlp.similarity", permission: "nlp") { body in
            NLP.similarity(body["a"] as? String ?? "", body["b"] as? String ?? "")
        },

        // Spotlight — one-shot NSMetadataQuery. Predicate string is raw
        // NSPredicate format ("kMDItemFSName LIKE[cd] '*.pdf'"); callers
        // must provide valid syntax (malformed predicates crash the daemon
        // — NSException isn't catchable from Swift). Scopes default to the
        // local computer; attributes default to a useful subset.
        .custom("spotlight.find", permission: "spotlight") { bridge, body, requestId in
            let predicate  = body["predicate"]  as? String
            let scopes     = body["scopes"]     as? [String]
            let attributes = body["attributes"] as? [String]
            let limit      = body["limit"]      as? Int
            Spotlight.find(predicate: predicate, scopes: scopes,
                           attributes: attributes, limit: limit) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },

        // Spotlight — long-lived NSMetadataQuery in continuous-update mode.
        // Each subscribe() mints a handle id; per-handle channel push uses
        // the synthesized name "spotlight:subscribe:<id>". JS
        // sd.spotlight.subscribe(opts) returns { id, subscribe(fn), stop() }
        // that wires the same channel name to the standard signal
        // machinery. First emit fires when the initial Spotlight gather
        // finishes; subsequent emits ride NSMetadataQueryDidUpdate. Same
        // predicate-crash caveat as spotlight.find: a malformed format
        // string raises NSInvalidArgumentException and brings down the
        // daemon — caller validates.
        .custom("spotlight.subscribe", permission: "spotlight") { bridge, body, requestId in
            let predicate  = body["predicate"]  as? String
            let scopes     = body["scopes"]     as? [String]
            let attributes = body["attributes"] as? [String]
            let limit      = body["limit"]      as? Int
            let id = bridge.nextSpotlightLiveId
            bridge.nextSpotlightLiveId += 1
            let channel = "spotlight:subscribe:\(id)"
            let live = Spotlight.LiveQuery(
                predicate: predicate,
                scopes:    scopes,
                attributes: attributes,
                limit:     limit,
                onUpdate:  { [weak bridge] entries in
                    guard let bridge = bridge else { return }
                    let json = Bridge.jsonify(entries)
                    bridge.push(channel: channel, json: json)
                }
            )
            guard let live = live else {
                // Empty / nil predicate — LiveQuery init? returns nil so
                // we don't mint a handle. Mirrors the find() empty-predicate
                // shortcut (returns []) but for subscribe there's nothing
                // to subscribe to, so the handle id is null and the JS
                // wrapper's start promise resolves to null.
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            bridge.spotlightLiveHandles[id] = Token { live.stop() }
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("spotlight.subscribe.stop", permission: "spotlight", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t  = b.spotlightLiveHandles.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },

        // Update — pending macOS software updates via `softwareupdate -l`.
        // No TCC; the list verb runs without escalation. The subprocess is
        // slow (5-10s, network round-trip), so the primitive caches the
        // result for ~6h by default. `force: true` busts the cache.
        .custom("update.list", permission: "update") { bridge, body, requestId in
            let force = body["force"] as? Bool ?? false
            let ttl   = body["ttlSeconds"] as? Double
            Update.list(force: force, ttlSeconds: ttl) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any)
            }
        },

        // Thumbnails — QLThumbnailGenerator one-shot. Renders the same
        // preview Finder/Quick Look show (PDF first page, video poster,
        // app icon, source highlight) for any file the user can read. No
        // TCC. Returns null on missing file / unrenderable type / timeout.
        .custom("thumbnails.generate", permission: "thumbnails") { bridge, body, requestId in
            let path           = body["path"] as? String ?? ""
            let w              = body["width"]  as? Double ?? 128
            let h              = body["height"] as? Double ?? 128
            let scale          = CGFloat(body["scale"] as? Double ?? Double(NSScreen.main?.backingScaleFactor ?? 2.0))
            let representation = body["representation"] as? String ?? "all"
            let format         = body["format"]  as? String ?? "png"
            let quality        = body["quality"] as? Double ?? 0.85
            let timeout        = body["timeoutSeconds"] as? Double ?? 5.0
            Thumbnails.generate(
                path:            path,
                size:            CGSize(width: w, height: h),
                scale:           scale,
                representation:  representation,
                format:          format,
                quality:         quality,
                timeoutSeconds:  timeout
            ) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },

        // Speech — text-to-speech via AVSpeechSynthesizer (no TCC, no
        // microphone — the engine runs entirely on the local audio device)
        // and speech-to-text via SFSpeechRecognizer + AVAudioEngine. STT
        // triggers TWO TCC prompts on first listen():
        //   - Microphone           (NSMicrophoneUsageDescription)
        //   - Speech Recognition   (NSSpeechRecognitionUsageDescription)
        // Per-handle channel push for listen() uses the synthesized name
        // "speech:listen:<id>" (mirrors bonjour.browse).
        .sync("speech.speak", permission: "speech", denyValue: false) { body in
            Speech.speak(
                text:   body["text"]   as? String ?? "",
                voice:  body["voice"]  as? String,
                rate:   (body["rate"]   as? Double).map { Float($0) },
                pitch:  (body["pitch"]  as? Double).map { Float($0) },
                volume: (body["volume"] as? Double).map { Float($0) }
            )
        },
        .sync("speech.stop", permission: "speech", denyValue: false) { body in
            Speech.stop(boundary: body["boundary"] as? String ?? "immediate")
        },
        .sync("speech.voices", permission: "speech", denyValue: [[String: Any]]()) { _ in
            Speech.voices()
        },
        // Supported recognizer locales (BCP-47 strings). One-shot read; the
        // set is static per OS install. No TCC — just an API query.
        .sync("speech.locales", permission: "speech", denyValue: [String]()) { _ in
            Speech.availableLocales()
        },
        // Start a continuous recognizer. Mints an id synchronously; the
        // recognizer + audio engine come up asynchronously inside the
        // Listener (TCC requests are async). Each partial result and the
        // final result are pushed through "speech:listen:<id>".
        .custom("speech.listen.start", permission: "speech") { bridge, body, requestId in
            let locale = body["locale"] as? String
            let requireOnDevice = (body["requireOnDevice"] as? Bool) ?? false
            let id = bridge.nextSpeechListenId
            bridge.nextSpeechListenId += 1
            let channel = "speech:listen:\(id)"
            // Capture id strongly inside the closures — the listener may
            // outlive the immediate respond() because TCC prompts are
            // user-paced. Errors fan out through the same channel as a
            // single push with { isFinal: true, error } so JS callers can
            // treat them uniformly.
            let listener = Speech.Listener(
                locale: locale,
                requireOnDevice: requireOnDevice,
                onResult: { [weak bridge] envelope in
                    guard let bridge = bridge else { return }
                    let json = Bridge.jsonify(envelope)
                    bridge.push(channel: channel, json: json)
                    // Final result → drop the handle so a follow-up stop()
                    // is a no-op (the listener already tore itself down
                    // inside its result callback).
                    if (envelope["isFinal"] as? Bool) == true {
                        bridge.speechListenHandles.removeValue(forKey: id)
                    }
                },
                onError: { [weak bridge] message in
                    guard let bridge = bridge else { return }
                    let envelope: [String: Any] = [
                        "text":     "",
                        "isFinal":  true,
                        "segments": [[String: Any]](),
                        "error":    message
                    ]
                    let json = Bridge.jsonify(envelope)
                    bridge.push(channel: channel, json: json)
                    bridge.speechListenHandles.removeValue(forKey: id)
                }
            )
            bridge.speechListenHandles[id] = Token { listener.stop() }
            listener.start(requireOnDevice: requireOnDevice)
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("speech.listen.stop", permission: "speech", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t  = b.speechListenHandles.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },
        // Convenience — stop every active listener owned by this stack.
        // Equivalent to calling stop() on each handle returned from
        // listen(), but useful for a "panic stop" UI affordance or page
        // teardown shortcut.
        .syncBridge("speech.listen.cancel", permission: "speech", denyValue: false) { b, _ in
            for (_, t) in b.speechListenHandles { t.cancel() }
            b.speechListenHandles.removeAll()
            return true
        },

        // Camera — one-shot frame grab. Triggers the Camera TCC prompt the
        // first time. `deviceId` matches sd.camera channel ids; nil = system
        // default. Format jpeg/png, quality 0..1 (jpeg only). Returns
        // { dataURL, width, height } or null. Pairs with sd.vision.*.
        .custom("camera.frame", permission: "camera") { bridge, body, requestId in
            let deviceId = body["deviceId"] as? String
            let format   = body["format"]   as? String ?? "jpeg"
            let quality  = body["quality"]  as? Double ?? 0.85
            let timeout  = body["timeoutSeconds"] as? Double ?? 3.0
            Camera.frame(deviceId: deviceId, format: format,
                         quality: quality, timeoutSeconds: timeout) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },

        // Camera streaming — long-lived AVCaptureSession that pushes one
        // dataURL payload per tick to a per-handle channel ("camera:stream:<id>").
        // Same handle-table + scope-drain pattern as bonjour.browse.start.
        // The first call triggers the Camera TCC prompt iff a prior
        // camera.frame hasn't already granted it. fps defaults to 10 and
        // is capped at 60 — caps documented on CameraStream.clampedFps.
        // Returns the handle id (JS wraps it as { id, subscribe, stop }),
        // or null if the device can't be opened.
        .custom("camera.stream.start", permission: "camera") { bridge, body, requestId in
            let deviceId = body["deviceId"] as? String
            let format   = CameraStream.normalizedFormat(body["format"] as? String)
            let quality  = CameraStream.clampedQuality(body["quality"] as? Double)
            let fps      = CameraStream.clampedFps(body["fps"] as? Double)
            let id = bridge.nextCameraStreamId
            bridge.nextCameraStreamId += 1
            let channel = "camera:stream:\(id)"
            let stream = Camera.openStream(
                deviceId: deviceId,
                format: format,
                quality: quality,
                fps: fps
            ) { [weak bridge] payload in
                guard let bridge = bridge else { return }
                let json = Bridge.jsonify(payload)
                bridge.push(channel: channel, json: json)
            }
            guard let stream = stream else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            bridge.cameraStreamHandles[id] = Token { stream.stop() }
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("camera.stream.stop", permission: "camera", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t  = b.cameraStreamHandles.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },

        // Calendar — read-only EventKit query. Triggers the Calendar TCC
        // prompt on first use. `from` / `to` are epoch seconds; `calendarIds`
        // optionally restricts to specific calendars (default = all).
        // Returns [] on denial, never nil.
        .custom("calendar.events", permission: "calendar") { bridge, body, requestId in
            let from = (body["from"] as? Double) ?? 0
            let to   = (body["to"]   as? Double) ?? 0
            let ids  = body["calendarIds"] as? [String]
            Calendar.events(from: from, to: to, calendarIds: ids) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? [[String: Any]]())
            }
        },
        .custom("calendar.list", permission: "calendar") { bridge, _, requestId in
            Calendar.calendars { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? [[String: Any]]())
            }
        },
        // Reminders — first call triggers the Reminders TCC prompt (separate
        // bucket from Calendar's). `list` filters to specific reminder-list
        // identifiers (EKCalendar.calendarIdentifier from sd.calendar.list
        // returns event calendars only — reminder lists need their own
        // future surface; for now pass nil to search all). `completed`:
        // nil → both, false → only incomplete, true → only completed.
        // Returns [] on denial, never nil.
        .custom("calendar.reminders", permission: "calendar") { bridge, body, requestId in
            let listIds   = body["list"]      as? [String]
            let completed = body["completed"] as? Bool
            Calendar.reminders(listIds: listIds, completed: completed) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? [[String: Any]]())
            }
        },
        // Create an event in `calendarId` (nil → default calendar for new
        // events). Returns the new event's identifier on success, null on
        // failure (denied access, missing calendar, save error). No new TCC
        // prompt — the Calendar full-access tier already granted via events()
        // covers writes too.
        .custom("calendar.createEvent", permission: "calendar") { bridge, body, requestId in
            let calId    = body["calendarId"] as? String
            let title    = body["title"]      as? String ?? ""
            let start    = (body["start"]     as? Double) ?? 0
            let end      = (body["end"]       as? Double) ?? 0
            let location = body["location"]   as? String
            let notes    = body["notes"]      as? String
            let allDay   = (body["allDay"]    as? Bool) ?? false
            Calendar.createEvent(
                calendarId: calId,
                title:      title,
                start:      start,
                end:        end,
                location:   location,
                notes:      notes,
                allDay:     allDay
            ) { [weak bridge] id in
                bridge?.respond(requestId: requestId, value: id as Any? ?? NSNull())
            }
        },

        // Privacy — "what's actively recording right now?" one-shot read.
        // Cross-references AVCaptureDevice.isInUseByAnotherApplication
        // (camera) and kAudioDevicePropertyDeviceIsRunningSomewhere
        // (microphone). Screen is empty in v1 — accurate process
        // attribution for screen capture needs private SPI (file-level
        // note in Privacy.swift). Returns the three-key shape always —
        // arrays may be empty but the keys are stable across versions.
        // Reads do NOT trigger camera / microphone TCC prompts (no stream
        // is ever opened — pure property reads).
        .sync("privacy.recording", permission: "privacy",
              denyValue: ["screen": [[String: Any]](), "camera": [[String: Any]](),
                          "microphone": [[String: Any]]()]) { _ in
            Privacy.recording()
        },

        // Bluetooth — paired device list via IOBluetooth. Triggers the
        // Bluetooth TCC prompt the first time. Returns [{ name?, address,
        // connected, classOfDevice?, services? }, ...]. Battery is a
        // focused follow-up (per-device-class private SPI).
        .sync("bluetooth.paired", permission: "bluetooth", denyValue: [[String: Any]]()) { _ in
            Bluetooth.paired()
        },

        // Vision OCR — VNRecognizeTextRequest. Async (perform() blocks on a
        // worker queue); image accepts a dataURL or an absolute file path.
        // Bounding boxes are y-flipped from Vision's normalized origin-bottom-
        // left to web-friendly top-left so JS overlays don't have to redo it.
        .custom("vision.ocr", permission: "vision") { bridge, body, requestId in
            let image = body["image"]
            let languages = body["languages"] as? [String]
            let level = body["recognitionLevel"] as? String ?? "accurate"
            Vision.ocr(image: image, languages: languages, level: level) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },

        // Vision faces — VNDetectFaceRectanglesRequest. Bounding rects + head
        // pose (roll/yaw/pitch when reportable). No recognition, no landmarks.
        .custom("vision.faces", permission: "vision") { bridge, body, requestId in
            Vision.faces(image: body["image"]) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },

        // Vision featurePrint — perceptual hash. Returns a base64 NSKeyedArchiver
        // blob; round-trip via vision.featurePrintDistance for similarity.
        .custom("vision.featurePrint", permission: "vision") { bridge, body, requestId in
            Vision.featurePrint(image: body["image"]) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },
        .sync("vision.featurePrintDistance", permission: "vision") { body in
            Vision.featurePrintDistance(a: body["a"] as? String,
                                        b: body["b"] as? String)
        },

        // Vision subjectMask — VNGenerateForegroundInstanceMaskRequest (macOS 14+).
        // Returns a PNG dataURL with the subject on transparent background, or
        // null on older macOS / failed extraction.
        .custom("vision.subjectMask", permission: "vision") { bridge, body, requestId in
            Vision.subjectMask(image: body["image"]) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },

        // Vision bodyPose — VNDetectHumanBodyPoseRequest. 17 named joints
        // per detected body, normalized to web-style top-left 0..1 coordinates.
        .custom("vision.bodyPose", permission: "vision") { bridge, body, requestId in
            Vision.bodyPose(image: body["image"]) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
            }
        },

        // ── SQLite ──────────────────────────────────────────────────────────
        // Minimal libsqlite3 wrapper — open / exec / query / close. Default
        // path lands under ~/stackd/stacks/<id>/data/ (sandbox-style); absolute
        // paths and ~ paths pass through. Handles are integers minted by a
        // process-wide store but ownership is per-Bridge so unload closes
        // every connection. Permission: "sqlite".
        .syncBridge("sqlite.open", permission: "sqlite") { b, body in
            let path = body["path"] as? String ?? ""
            let mode = body["mode"] as? String ?? "readwrite"
            guard let result = SQLite.open(stackId: b.stackId, path: path, mode: mode) else {
                return NSNull()
            }
            if let h = result["handle"] as? Int { b.sqliteHandles.insert(h) }
            return result
        },
        .syncBridge("sqlite.exec", permission: "sqlite") { _, body in
            SQLite.exec(
                handle: body["handle"] as? Int ?? -1,
                sql:    body["sql"]    as? String ?? "")
        },
        .syncBridge("sqlite.query", permission: "sqlite") { _, body in
            SQLite.query(
                handle: body["handle"] as? Int ?? -1,
                sql:    body["sql"]    as? String ?? "",
                params: body["params"] as? [Any] ?? [])
        },
        .syncBridge("sqlite.close", permission: "sqlite", denyValue: false) { b, body in
            guard let h = body["handle"] as? Int else { return false }
            b.sqliteHandles.remove(h)
            return SQLite.close(handle: h)
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

        // Streamed proc — progressive stdout/stderr via per-chunk callbacks,
        // SIGTERM via cancel. Mints an id (returned synchronously to JS);
        // each chunk + the final exit event fire via __sd_proc_stream_fire.
        // Same handle-table pattern as broadcasts.observe / hotkey.bind.
        .custom("proc.stream.start", permission: "proc") { bridge, body, requestId in
            let cmd  = body["cmd"]  as? String ?? ""
            let args = body["args"] as? [String] ?? []
            let env  = body["env"]  as? [String: String]
            let cwd  = body["cwd"]  as? String
            let id = bridge.nextProcStreamId
            bridge.nextProcStreamId += 1
            let handle = Proc.stream(cmd: cmd, args: args, env: env, cwd: cwd) { [weak bridge] payload in
                guard let bridge = bridge, let webView = bridge.webView else { return }
                let json = Bridge.jsonify(payload)
                // Proc.stream already hops to main before invoking onEvent;
                // evaluateJavaScript runs synchronously from here.
                webView.evaluateJavaScript(
                    "window.__sd_proc_stream_fire && window.__sd_proc_stream_fire(\(id), \(json));",
                    completionHandler: nil
                )
                // Final event drops the handle so cancel() after exit no-ops
                // and the per-stack drain doesn't try to SIGTERM a dead child.
                if (payload["stream"] as? String) == "exit" {
                    bridge.procStreamHandles.removeValue(forKey: id)
                }
            }
            guard let handle = handle else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            bridge.procStreamHandles[id] = handle
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("proc.stream.cancel", permission: "proc", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let h = b.procStreamHandles[id] else { return false }
            h.cancel()
            // Don't remove from the table here — the exit event handler does
            // that. Removing now would let a subsequent cancel slip through
            // as "not found" even though the SIGTERM was already in flight.
            return true
        },

        // Shortcuts CLI invocation — async like proc.exec. Gated by the
        // "shortcuts" permission so a stack must opt in explicitly (a shortcut
        // can do almost anything: AppleScript, file I/O, network requests,
        // automations chained to other apps). The first call also surfaces
        // the macOS Shortcuts TCC prompt if access hasn't been granted.
        .custom("shortcuts.run", permission: "shortcuts") { bridge, body, requestId in
            Shortcuts.run(
                name:    body["name"]  as? String ?? "",
                input:   body["input"] as? String,
                timeoutSeconds: body["timeout"] as? Double
            ) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result)
            }
        },

        // AppleScript / JXA — async hop to main. OSAKit is Apple Event-based
        // and depends on the main runloop for inter-process AEs (tell app "X").
        .custom("applescript.run", permission: "applescript") { bridge, body, requestId in
            let src     = body["source"]   as? String ?? ""
            let lang    = body["language"] as? String ?? "applescript"
            let timeout = body["timeout"]  as? Double ?? 10
            DispatchQueue.main.async { [weak bridge] in
                let result = AppleScript.run(source: src, language: lang, timeoutSeconds: timeout)
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
        // Update the runtime cursor-rect gate for a consumer eventtap declared
        // in this stack's manifest (`callback` matches the eventtap entry's
        // `callback`). Body shape:
        //   { callback: "snapshotsLeftClick",
        //     rects: [{x,y,w,h}, ...] | null }
        // null → clear gate (consume on predicate alone — original behavior).
        // empty [] → empty gate (consumer never matches; suppresses without
        //   unregistering).
        // populated → consume only when cursor falls in any rect (top-left
        //   origin global screen coords, same space as sd.windows.byId.frame).
        // Returns true on accept, false when the callback name isn't a
        // consumer this stack registered (defensive — silent mis-keying
        // would otherwise hide a typo behind a no-op).
        .syncBridge("events.setTapRects", permission: "events", denyValue: false) { bridge, body in
            guard let callback = body["callback"] as? String, !callback.isEmpty else { return false }
            let key = "\(bridge.stackId):\(callback)"
            if body["rects"] is NSNull || body["rects"] == nil {
                EventTapRegistry.shared.setConsumerRects(key: key, rects: nil)
                return true
            }
            guard let arr = body["rects"] as? [[String: Any]] else { return false }
            let rects: [CGRect] = arr.map { d in
                CGRect(
                    x: (d["x"] as? Double) ?? Double((d["x"] as? Int) ?? 0),
                    y: (d["y"] as? Double) ?? Double((d["y"] as? Int) ?? 0),
                    width:  (d["w"] as? Double) ?? Double((d["w"] as? Int) ?? 0),
                    height: (d["h"] as? Double) ?? Double((d["h"] as? Int) ?? 0)
                )
            }
            EventTapRegistry.shared.setConsumerRects(key: key, rects: rects)
            return true
        },

        // Cursor — warp / read. setPosition takes top-left global coords
        // (same convention as sd.mouse / sd.events.click); pass `display`
        // to interpret coords as display-local. Gated on a separate "cursor"
        // permission rather than folding under "events": warping doesn't fire
        // a CGEvent that other taps observe, so it's a different threat surface
        // than the events.* synthesizers.
        .sync("cursor.setPosition", permission: "cursor", denyValue: false) { body in
            let displayID = (body["display"] as? Int).map { CGDirectDisplayID($0) }
            return Cursor.setPosition(
                x: body["x"] as? Double ?? 0,
                y: body["y"] as? Double ?? 0,
                display: displayID)
        },
        .sync("cursor.position", permission: "cursor") { _ in Cursor.position() },

        // Apps — Bool side-effect ops, deny → false.
        .sync("apps.launch", permission: "apps", denyValue: false) { body in Apps.launch(bundleId: body["bundleId"] as? String ?? "") },
        .sync("apps.focus",  permission: "apps", denyValue: false) { body in Apps.focus( bundleId: body["bundleId"] as? String ?? "") },
        .sync("apps.kill",   permission: "apps", denyValue: false) { body in Apps.kill(  bundleId: body["bundleId"] as? String ?? "", force: body["force"] as? Bool ?? false) },
        .sync("apps.hide",   permission: "apps", denyValue: false) { body in Apps.hide(  bundleId: body["bundleId"] as? String ?? "") },

        // Curated AX readers on a pid (mirrors hs.application's menu /
        // findMenuItem / selectMenuItem / visibleWindows / hide / unhide).
        // All hop to main via `.ax` because they walk AXUIElement trees —
        // same constraint that put windows.byId.cornerHints behind `.ax`.
        // hide / unhide are pid-specific (the bundleId variant lives above
        // as apps.hide); the JS surface routes `sd.apps.hide(pid)` → hideByPid.
        .ax("apps.menu", permission: "apps") { _, body in
            Apps.menu(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .ax("apps.findMenuItem", permission: "apps") { _, body in
            Apps.findMenuItem(
                pid: pid_t((body["pid"] as? Int) ?? 0),
                path: (body["path"] as? [String]) ?? []
            )
        },
        .ax("apps.selectMenuItem", permission: "apps", denyValue: false) { _, body in
            Apps.selectMenuItem(
                pid: pid_t((body["pid"] as? Int) ?? 0),
                path: (body["path"] as? [String]) ?? []
            )
        },
        .ax("apps.visibleWindows", permission: "apps", denyValue: [[String: Any]]()) { _, body in
            Apps.visibleWindows(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .ax("apps.hideByPid", permission: "apps", denyValue: false) { _, body in
            Apps.hide(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .ax("apps.unhideByPid", permission: "apps", denyValue: false) { _, body in
            Apps.unhide(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        // Per-pid window-set readers. Return CGWindowID(s); JS chains into
        // sd.windows.byId.* from there. `.ax` (main-hop) because they walk
        // the AX tree, same constraint as `visibleWindows` above.
        .ax("apps.focusedWindow", permission: "apps") { _, body in
            Apps.focusedWindow(pid: pid_t((body["pid"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("apps.mainWindow", permission: "apps") { _, body in
            Apps.mainWindow(pid: pid_t((body["pid"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("apps.allWindows", permission: "apps", denyValue: [Int]()) { _, body in
            Apps.allWindows(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        // Per-pid app state. Pure AppKit — `.sync` (no main-hop) because
        // NSWorkspace.frontmostApplication / NSRunningApplication.isHidden
        // are thread-safe AppKit reads with no AX gate.
        .sync("apps.isFrontmost", permission: "apps", denyValue: false) { body in
            Apps.isFrontmost(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .sync("apps.isHidden", permission: "apps", denyValue: false) { body in
            Apps.isHidden(pid: pid_t((body["pid"] as? Int) ?? 0))
        },

        // Curated AX surface for the system-wide focused text element.
        // Replaces the five-call sd.ax.{focused,attribute,parameterizedAttribute,
        // release} dance muse / palette / text-expander stacks used to do for
        // every transformation tick. `.ax` (main-hop) because AX traffic
        // deadlocks under cross-thread access — same constraint that put
        // apps.menu behind `.ax`. Reader returns nil when no AX-text element
        // has focus; setters return false on the same condition.
        .ax("input.focusedText", permission: "input") { _, _ in
            InputAX.focusedText() as Any? ?? NSNull()
        },
        .ax("input.setSelectedText", permission: "input", denyValue: false) { _, body in
            InputAX.setSelectedText(body["value"] as? String ?? "")
        },
        .ax("input.setSelectedRange", permission: "input", denyValue: false) { _, body in
            InputAX.setSelectedRange(
                location: (body["location"] as? Int) ?? 0,
                length:   (body["length"]   as? Int) ?? 0
            )
        },

        // Icons
        .sync("icons.app",  permission: "icons") { body in
            Icons.forApp( bundleId: body["bundleId"] as? String ?? "", size: body["size"] as? Int ?? 64)
        },
        .sync("icons.file", permission: "icons") { body in
            Icons.forFile(path: body["path"] as? String ?? "", size: body["size"] as? Int ?? 64)
        },

        // Windows — focused-window helpers operate on the AX focused window
        // of frontmost app. All Bool-returning except byId.frame (returns
        // dict or nil). These hop to main via `.ax` because the underlying
        // AXUIElementSetAttributeValue calls deadlock or silently partial-
        // apply when invoked from a non-main thread (same constraint that
        // moved the .ax.* surface). Concretely: WindowScape's per-tick
        // setFrame loop would land position but drop size on ~half the
        // calls, leaving windows moved-but-not-resized — the "windows
        // resize incorrectly" symptom.
        .ax("windows.setFrame",   permission: "windows", denyValue: false) { _, body in
            Windows.setFocusedFrame(
                x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                w: body["w"] as? Double ?? 0, h: body["h"] as? Double ?? 0)
        },
        .ax("windows.minimize",   permission: "windows", denyValue: false) { _, body in Windows.minimizeFocused(body["value"] as? Bool ?? true) },
        .ax("windows.fullscreen", permission: "windows", denyValue: false) { _, body in Windows.fullscreenFocused(body["value"] as? Bool ?? true) },
        .ax("windows.raise",      permission: "windows", denyValue: false) { _, _    in Windows.raiseFocused() },

        // Windows-by-id
        .ax("windows.byId.setFrame",   permission: "windows", denyValue: false) { _, body in
            WindowsByID.setFrame(
                windowID: CGWindowID((body["id"] as? Int) ?? 0),
                x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                w: body["w"] as? Double ?? 0, h: body["h"] as? Double ?? 0)
        },
        // Probed setFrame: applies the geometry then reads back what AX
        // actually accepted. Use this when you want to detect apps that
        // refused part of the resize (Calculator, Browser at min width,
        // fixed-size panels) so callers can build a constraint cache.
        // Returns { ok: Bool, actual: {x,y,w,h} | null }.
        .ax("windows.byId.setFrameProbed", permission: "windows") { _, body in
            WindowsByID.setFrameProbed(
                windowID: CGWindowID((body["id"] as? Int) ?? 0),
                x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                w: body["w"] as? Double ?? 0, h: body["h"] as? Double ?? 0) as [String: Any]
        },
        .ax("windows.byId.minimize",   permission: "windows", denyValue: false) { _, body in WindowsByID.minimize(  windowID: CGWindowID((body["id"] as? Int) ?? 0), body["value"] as? Bool ?? true) },
        .ax("windows.byId.fullscreen", permission: "windows", denyValue: false) { _, body in WindowsByID.fullscreen(windowID: CGWindowID((body["id"] as? Int) ?? 0), body["value"] as? Bool ?? true) },
        .ax("windows.byId.raise",      permission: "windows", denyValue: false) { _, body in WindowsByID.raise(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
        .ax("windows.byId.focus",      permission: "windows", denyValue: false) { _, body in WindowsByID.focus(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
        .ax("windows.byId.close",      permission: "windows", denyValue: false) { _, body in WindowsByID.close(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
        .ax("windows.byId.frame",      permission: "windows") { _, body in
            guard let r = WindowsByID.frame(windowID: CGWindowID((body["id"] as? Int) ?? 0)) else { return nil }
            return [
                "x": Int(r.origin.x), "y": Int(r.origin.y),
                "w": Int(r.size.width), "h": Int(r.size.height)
            ] as [String: Any]
        },
        .ax("windows.byId.cornerHints", permission: "windows") { _, body in
            WindowsByID.cornerHints(windowID: CGWindowID((body["id"] as? Int) ?? 0))
        },
        // Traffic-light button rects — one AX walk reads close + zoom +
        // minimize button frames so stacks can intercept clicks on the
        // native dots (windowscape routes the yellow dot to its snapshot
        // subsystem). Returns NSNull (→ JS null) when the window is
        // unaddressable; per-button fields are NSNull when that dot doesn't
        // exist on the window (panels, helper windows).
        .ax("windows.byId.buttonFrames", permission: "windows") { _, body in
            WindowsByID.buttonFrames(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        // Batch reader — one AX lookup, all curated readers in one payload.
        // Replaces 4-9 sequential round-trips at attach/render time.
        .ax("windows.byId.info",        permission: "windows") { _, body in
            WindowsByID.info(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        // Curated AX readers — per-window properties without round-tripping
        // through `sd.ax.*`. Each maps 1:1 to a WindowsByID static; `.ax`
        // because AX queries must hop to main. nil/false results pass through
        // as JSON null / false, matching the byId.frame contract.
        .ax("windows.byId.title",        permission: "windows") { _, body in
            WindowsByID.title(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("windows.byId.role",         permission: "windows") { _, body in
            WindowsByID.role(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("windows.byId.subrole",      permission: "windows") { _, body in
            WindowsByID.subrole(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("windows.byId.isMinimized",  permission: "windows") { _, body in
            WindowsByID.isMinimized(windowID: CGWindowID((body["id"] as? Int) ?? 0))
        },
        .ax("windows.byId.isFullscreen", permission: "windows") { _, body in
            WindowsByID.isFullscreen(windowID: CGWindowID((body["id"] as? Int) ?? 0))
        },
        .ax("windows.byId.hasToolbar",   permission: "windows") { _, body in
            WindowsByID.hasToolbar(windowID: CGWindowID((body["id"] as? Int) ?? 0))
        },
        .ax("windows.byId.isStandard",   permission: "windows") { _, body in
            WindowsByID.isStandard(windowID: CGWindowID((body["id"] as? Int) ?? 0))
        },
        // Per-window tab list — walks the AXTabGroup child once. Returns
        // [{title, selected}] when a tab group exists, [] if it has no
        // children, NSNull (→ JSON null) when the window has no AXTabGroup.
        .ax("windows.byId.tabs",         permission: "windows") { _, body in
            WindowsByID.tabs(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("windows.byId.focusTab",     permission: "windows", denyValue: false) { _, body in
            WindowsByID.focusTab(
                windowID: CGWindowID((body["id"] as? Int) ?? 0),
                index: (body["index"] as? Int) ?? 0
            )
        },
        // Per-window snapshot via CGSHWCaptureWindowList (AltTab's trick).
        // Synchronous, no TCC, works for hidden / minimized / off-space
        // windows. Distinct from sd.display.snapshot (ScreenCaptureKit).
        // `quality` is taken as-is — the canonical 0.85 default is declared
        // in Runtime/api.js (`sd.windows.snapshot`). If the field arrives
        // missing here we leave it nil and the encode falls back internally.
        .sync("windows.byId.snapshot",   permission: "windows") { body in
            WindowsByID.snapshot(
                windowID: CGWindowID((body["id"] as? Int) ?? 0),
                format:   body["format"]  as? String ?? "png",
                quality:  body["quality"] as? Double
            )
        },

        // Atomic multi-window transaction. begin opens a fresh SLSTransaction
        // and installs the WindowsByID.batchSink that funnels per-id setFrame
        // calls (and future per-id windows mutations) into it; commit calls
        // SLSTransactionCommit and clears the sink. Process-global — if a
        // batch is already open the begin refuses rather than nest, matching
        // the JS-side single-await model. Hops to main because both AX and
        // the SkyLight tx symbols want the WindowServer connection thread.
        .custom("windows.batch.begin", permission: "windows", denyValue: false) { bridge, _, requestId in
            DispatchQueue.main.async { [weak bridge] in
                bridge?.respond(requestId: requestId, value: WindowsByID.beginBatch())
            }
        },
        .custom("windows.batch.commit", permission: "windows", denyValue: false) { bridge, _, requestId in
            DispatchQueue.main.async { [weak bridge] in
                bridge?.respond(requestId: requestId, value: WindowsByID.commitBatch())
            }
        },

        // Spaces — returns array; pre-refactor returned `[]` on deny.
        .sync("spaces.windowSpaces", permission: "spaces", denyValue: [NSNumber]()) { body in
            Spaces.windowSpaces(windowID: UInt32((body["id"] as? Int) ?? 0)).map { NSNumber(value: $0) }
        },
        .sync("spaces.minimizedWindows", permission: "spaces", denyValue: [NSNumber]()) { body in
            let id = UInt64((body["spaceID"] as? Int) ?? 0)
            return Spaces.minimizedWindows(spaceID: id).map { NSNumber(value: $0) }
        },

        // Accessibility — all .ax variants hop to main and have access to axHandles via bridge
        .ax("ax.focused") { _, _ in AX.focusedElement() },
        .ax("ax.application")             { b, body in AX.application(pid: pid_t((body["pid"] as? Int) ?? 0), store: b.axHandles) },
        .ax("ax.system")                  { b, _    in AX.systemWide(store: b.axHandles) },
        .ax("ax.systemElementAtPosition") { b, body in AX.systemElementAtPosition(x: Float((body["x"] as? Double) ?? 0), y: Float((body["y"] as? Double) ?? 0), store: b.axHandles) },
        .ax("ax.focusedElement")          { b, _    in AX.focusedElementHandle(store: b.axHandles) },
        .ax("ax.focusedElementSystemWide"){ b, _    in AX.focusedElementSystemWideHandle(store: b.axHandles) },
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
        // JS-controlled window alpha. Not gated to invocable — any stack can
        // fade its panel (SideSwipe's volume/brightness disc, transient toasts,
        // anything that wants the whole window to fade rather than just the
        // WebView contents — CSS opacity on body doesn't reach the
        // NSGlassEffectView's glass layer).
        //
        // First call disables the FirstPaintGate's auto-reveal — see
        // StackWindow.setAlpha / FirstPaintGate.markOverridden.
        .custom("window.setAlpha", denyValue: false) { bridge, body, requestId in
            guard let alpha = StackWindow.parseSetAlpha(body) else {
                bridge.respond(requestId: requestId, value: false)
                return
            }
            DispatchQueue.main.async { [weak bridge] in
                if let win = bridge?.webView?.window as? StackWindow {
                    win.setAlpha(alpha)
                    bridge?.respond(requestId: requestId, value: true)
                } else {
                    bridge?.respond(requestId: requestId, value: false)
                }
            }
        },
        // JS-controlled window frame. Input is in CG/AX convention (top-left
        // origin) — matches sd.windows.focused / sd.ax.attribute. Width / height
        // optional; omitted dimensions preserve current. Used by stacks that
        // reposition per-invocation (Muse anchors to AX-focused element) where
        // a single manifest anchor isn't expressive enough.
        .custom("window.setFrame", denyValue: false) { bridge, body, requestId in
            guard let f = StackWindow.parseSetFrame(body) else {
                bridge.respond(requestId: requestId, value: false)
                return
            }
            DispatchQueue.main.async { [weak bridge] in
                if let win = bridge?.webView?.window as? StackWindow {
                    win.setFrame(cgX: f.x, cgY: f.y, w: f.w, h: f.h)
                    bridge?.respond(requestId: requestId, value: true)
                } else {
                    bridge?.respond(requestId: requestId, value: false)
                }
            }
        },
        // JS-controlled click-through. Bar-like stacks toggle this to route
        // events between themselves and the system menubar underneath as the
        // mouse moves over / off their item rects.
        .custom("window.setClickThrough", denyValue: false) { bridge, body, requestId in
            guard let v = StackWindow.parseSetClickThrough(body) else {
                bridge.respond(requestId: requestId, value: false)
                return
            }
            DispatchQueue.main.async { [weak bridge] in
                if let win = bridge?.webView?.window as? StackWindow {
                    win.setClickThrough(v)
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

        // Read-only AX walk of every visible menubar status item. Used by
        // menubar-manager stacks to enumerate what's in the bar — third-
        // party app icons + Apple's Spotlight + clock. macOS 14+ Control
        // Center cluster lives in a separate AXSystemUIServer process and
        // is not enumerable from systemWide; documented as a limitation.
        // Folded under the existing "menubar" permission (same gate as
        // suppress/restore + the menubar.observe channel).
        .sync("menubar.items", permission: "menubar", denyValue: [[String: Any]]()) { _ in
            MenubarItems.items()
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
            // Optional skhd-style scoping. `mode` gates dispatch on the
            // active HotkeyRegistry mode; `apps` whitelists the frontmost
            // app's bundleID; `excludeApps` blacklists it. All nil = current
            // always-on behavior. apps + excludeApps compose (both must pass).
            let mode = body["mode"] as? String
            let apps = body["apps"] as? [String]
            let excludeApps = body["excludeApps"] as? [String]
            let id = bridge.nextHotkeyId
            bridge.nextHotkeyId += 1
            let token = HotkeyRegistry.shared.bind(
                spec: spec, mode: mode, apps: apps, excludeApps: excludeApps
            ) { [weak bridge] in
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

        // Modal keymaps (skhd). Entering a mode suppresses every binding
        // declared for a different mode until exit; bindings with no mode
        // declared (mode == nil) stay always-on so the chord that exits the
        // mode itself can be expressed. Mode is GLOBAL — a single string
        // shared across stacks, matching skhd's "the keyboard is one
        // resource" model. Folded under the existing "hotkey" permission.
        .sync("hotkey.mode.enter", permission: "hotkey", denyValue: false) { body in
            guard let name = body["name"] as? String else { return false }
            HotkeyRegistry.shared.enterMode(name)
            return true
        },
        .sync("hotkey.mode.exit", permission: "hotkey", denyValue: false) { _ in
            HotkeyRegistry.shared.exitMode()
            return true
        },
        .sync("hotkey.mode.current", permission: "hotkey") { _ in
            HotkeyRegistry.shared.currentMode
        },

        // ── Generic NSDistributedNotificationCenter observer ─────────────────
        // Complements Caffeinate (which hard-codes screenIsLocked / screenIsUnlocked):
        // here the stack picks the notification name. Same mint-id + window-global
        // fire pattern as hotkey.bind. Permission: "broadcasts".
        .custom("broadcasts.observe", permission: "broadcasts") { bridge, body, requestId in
            guard let name = body["name"] as? String else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            let id = bridge.nextBroadcastId
            bridge.nextBroadcastId += 1
            let token = Broadcasts.observe(name: name) { [weak bridge] payload in
                guard let webView = bridge?.webView else { return }
                let json = Bridge.jsonify(payload)
                DispatchQueue.main.async {
                    webView.evaluateJavaScript("window.__sd_broadcast_fire && window.__sd_broadcast_fire(\(id), \(json));",
                                               completionHandler: nil)
                }
            }
            bridge.broadcastTokens[id] = token
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("broadcasts.unobserve", permission: "broadcasts", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t = b.broadcastTokens.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },

        // ── Custom URL scheme handler ──────────────────────────────────────
        // Register a callback for `<scheme>://…` URLs opened by other apps.
        // NSAppleEventManager's GURL handler is installed lazily on first
        // subscribe and stays for the daemon lifetime; per-stack subscribers
        // live in a SchemeRouter bucket and drain on stack unload.
        //
        // Limitation: macOS only ROUTES a custom scheme to stackd if the
        // daemon's Info.plist declares it under CFBundleURLTypes. Today the
        // daemon ships as a plain `.build/stackd` binary (no Info.plist),
        // so the API surface works but URL events won't actually arrive
        // until stackd ships as an `.app` bundle with the scheme declared.
        // See Sources/DataSources/URLHandler.swift for the rationale.
        //
        // Same mint-id + window-global fire pattern as broadcasts.observe.
        // Permission: "urlhandler".
        .custom("urlhandler.register", permission: "urlhandler") { bridge, body, requestId in
            guard let scheme = body["scheme"] as? String, !scheme.isEmpty else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            let id = bridge.nextURLHandlerId
            bridge.nextURLHandlerId += 1
            let token = URLHandler.observe(scheme: scheme) { [weak bridge] payload in
                guard let webView = bridge?.webView else { return }
                let json = Bridge.jsonify(payload)
                DispatchQueue.main.async {
                    webView.evaluateJavaScript("window.__sd_urlhandler_fire && window.__sd_urlhandler_fire(\(id), \(json));",
                                               completionHandler: nil)
                }
            }
            bridge.urlHandlerTokens[id] = token
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("urlhandler.unregister", permission: "urlhandler", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t = b.urlHandlerTokens.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },

        // ── Caffeinate.assert (wake-lock setter) ───────────────────────────
        // Mints an IOPMAssertion held until release. Three JS types map to
        // three IOPM assertion strings — see Caffeinate.assert(type:reason:).
        // Returns a per-bridge handle id; JS wraps it as { id, release() }.
        // Stack unload drains every outstanding assertion via scope so a
        // forgotten wake-lock can't outlive the stack. Permission: "caffeinate".
        .custom("caffeinate.assert", permission: "caffeinate") { bridge, body, requestId in
            // The IPC envelope already owns the "type" key (used to dispatch
            // to this primitive), so the assertion kind comes in on
            // "assertionType" — JS api.js renames spec.type accordingly.
            let kind = body["assertionType"] as? String ?? ""
            let reason = body["reason"] as? String ?? ""
            guard let assertionId = Caffeinate.assert(type: kind, reason: reason) else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            let id = bridge.nextCaffeinateId
            bridge.nextCaffeinateId += 1
            bridge.caffeinateAssertions[id] = assertionId
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("caffeinate.release", permission: "caffeinate", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let assertionId = b.caffeinateAssertions.removeValue(forKey: id) else { return false }
            return Caffeinate.release(id: assertionId)
        },

        // ── Overlay (WebKit overlay primitive) ─────────────────────────────
        // Attach a borderless click-through NSPanel + WKWebView pinned to a
        // target window we don't own. The stack supplies {html, css?, js?};
        // per vsync we reposition the panel to SLSGetWindowBounds(targetWID)
        // and push `window.sd.target = {x,y,w,h}` into the overlay's WebView.
        // The daemon is observe + set only — no CGContext drawing, no spec
        // DSL. Rendering is plain WebKit. Permission: "overlay".
        .custom("overlay.attach", permission: "overlay") { bridge, body, requestId in
            DispatchQueue.main.async { [weak bridge] in
                guard let bridge = bridge,
                      let wid = body["targetId"] as? Int else {
                    bridge?.respond(requestId: requestId, value: NSNull()); return
                }
                let html = body["html"] as? String ?? ""
                let css  = body["css"]  as? String ?? ""
                let js   = body["js"]   as? String ?? ""
                let id = bridge.nextOverlayId
                bridge.nextOverlayId += 1
                guard let handle = Overlay.attach(
                    targetID: CGWindowID(wid), id: id,
                    html: html, css: css, js: js
                ) else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                bridge.overlayHandles[id] = handle

                // Vsync tick → reposition + sd.target push. We subscribe to
                // the shared DisplayLinkObserver (also drives sd.displayLink)
                // so multiple overlays share one CVDisplayLink —
                // RefCountedObserver handles install/teardown.
                let token = DisplayLinkObserver.shared.subscribe { [weak bridge] in
                    guard let bridge = bridge,
                          let h = bridge.overlayHandles[id] else { return }
                    // Target gone or hidden (user closed / minimized /
                    // cmd-H'd the underlying window mid-overlay): hide
                    // the panel and bail. Without this, the panel stayed
                    // drawn at lastFrame after the target vanished — a
                    // ghost border floating in space. Show it again on
                    // the next tick where the target returns (e.g. user
                    // un-minimizes).
                    guard Overlay.isOrderedIn(h.targetWID),
                          let frame = Overlay.bounds(of: h.targetWID) else {
                        if h.panel.isVisible { h.panel.orderOut(nil) }
                        return
                    }
                    if !h.panel.isVisible { h.panel.orderFrontRegardless() }
                    h.tick(targetFrame: frame)
                }
                bridge.overlayTokens[id] = token
                bridge.respond(requestId: requestId, value: id)
            }
        },
        // Retarget an existing overlay at a new window without tearing it
        // down. Used by overlay-border to keep one overlay across the
        // session and just move/resize it on focus change — the prior
        // detach-then-attach cycle produced ghost borders when detach
        // didn't complete before the next attach ran.
        .syncBridge("overlay.setTarget", permission: "overlay", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let wid = body["targetId"] as? Int,
                  let handle = b.overlayHandles[id] else { return false }
            if Thread.isMainThread {
                handle.setTarget(CGWindowID(wid))
            } else {
                DispatchQueue.main.sync { handle.setTarget(CGWindowID(wid)) }
            }
            return true
        },
        // Evaluate arbitrary JS in the overlay's WebView. Pairs with
        // setTarget so the stack can update the overlay's appearance
        // (color, radius, theme) when retargeting. The overlay's WebView
        // is otherwise opaque to the host stack — no postMessage channel.
        .syncBridge("overlay.eval", permission: "overlay", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let js = body["js"] as? String,
                  let handle = b.overlayHandles[id] else { return false }
            if Thread.isMainThread {
                handle.evaluate(js)
            } else {
                DispatchQueue.main.sync { handle.evaluate(js) }
            }
            return true
        },
        // Tear down: cancel the displayLink subscription, then close the
        // overlay NSPanel. Detaching does NOT touch the target window.
        .syncBridge("overlay.detach", permission: "overlay", denyValue: false) { b, body in
            guard let id = body["id"] as? Int else { return false }
            if let token = b.overlayTokens.removeValue(forKey: id) { token.cancel() }
            if let handle = b.overlayHandles.removeValue(forKey: id) {
                // Synchronous teardown — the JS-side await must not resolve
                // until the NSPanel is actually gone. The old async path
                // returned success while the panel was still onscreen, so
                // a follow-up attach (focus change, hot-reload) produced
                // two overlays visible at the same time. handle.detach is
                // already main-thread-safe (it sync-hops if needed); we
                // sync-hop here too rather than fire-and-forget.
                if Thread.isMainThread {
                    handle.detach()
                } else {
                    DispatchQueue.main.sync { handle.detach() }
                }
            }
            b.overlayInFlight.remove(id)
            return true
        },

        // ── HTTP server ─────────────────────────────────────────────────────
        // Long-running Network.framework listener owned by the stack. Every
        // request fans out to JS via __sd_http_request(serverId, requestId,
        // {method,path,query,headers,body}). JS replies with
        // sd.httpserver.respond(reqId, {status,headers,body}). Stacks own all
        // dispatch logic — route matching, CORS headers, Content-Type — in JS.
        // Loopback-only unless bindHost === "0.0.0.0". Permission: "httpserver".
        .custom("httpserver.serve", permission: "httpserver") { bridge, body, requestId in
            let port = UInt16((body["port"] as? Int) ?? 0)
            let bindHost = body["bindHost"] as? String ?? "127.0.0.1"
            let bonjourType: String? = (body["bonjour"] as? [String: Any])?["type"] as? String
            let bonjourName: String? = (body["bonjour"] as? [String: Any])?["name"] as? String

            let serverId = bridge.nextHttpId
            bridge.nextHttpId += 1
            do {
                let server = try HTTPServer(
                    port: port,
                    bindHost: bindHost,
                    bonjourType: bonjourType,
                    bonjourName: bonjourName
                ) { [weak bridge] req, complete in
                    guard let bridge = bridge else {
                        complete(HTTPResponse(status: 503)); return
                    }
                    DispatchQueue.main.async {
                        let reqId = bridge.nextHttpId
                        bridge.nextHttpId += 1
                        bridge.pendingHttpResponses[reqId] = complete
                        let payload: [String: Any] = [
                            "method":  req.method,
                            "path":    req.path,
                            "query":   req.query,
                            "headers": req.headers,
                            "body":    req.body
                        ]
                        let json = Bridge.jsonify(payload)
                        bridge.webView?.evaluateJavaScript(
                            "window.__sd_http_request && window.__sd_http_request(\(serverId), \(reqId), \(json));",
                            completionHandler: nil
                        )
                    }
                }
                server.start()
                let token = Token { server.stop() }
                bridge.httpServerTokens[serverId] = token
                bridge.respond(requestId: requestId, value: serverId)
            } catch {
                FileHandle.standardError.write(Data("stackd: httpserver bind failed on :\(port) — \(error)\n".utf8))
                bridge.respond(requestId: requestId, value: NSNull())
            }
        },
        .syncBridge("httpserver.stop", permission: "httpserver", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let token = b.httpServerTokens.removeValue(forKey: id) else { return false }
            token.cancel()
            return true
        },
        // No permission gate on respond — sending a reply to an in-flight
        // request the stack already accepted is always safe. Without this
        // exemption, manifest authors would have to remember "httpserver"
        // on the respond side too, which is friction the API doesn't need.
        .syncBridge("httpserver.respond", permission: nil, denyValue: false) { b, body in
            guard let reqId = body["reqId"] as? Int,
                  let complete = b.pendingHttpResponses.removeValue(forKey: reqId) else {
                return false
            }
            var response = HTTPResponse()
            response.status  = body["status"] as? Int ?? 200
            response.headers = body["headers"] as? [String: String] ?? [:]
            let raw = body["body"] as? String ?? ""
            // Stacks opt into binary by passing bodyEncoding: "base64" — typical
            // pairing is sd.fs.read(path, { encoding: "base64" }) → forward the
            // string straight through. Anything else (or missing) treats body as
            // a UTF-8 string, matching the original String-only contract.
            if (body["bodyEncoding"] as? String) == "base64",
               let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]) {
                response.bodyBytes = data
            } else {
                response.body = raw
            }
            complete(response)
            return true
        },

        // ── Bonjour / mDNS ──────────────────────────────────────────────────
        // Publish: long-lived NWListener that advertises {name, type, port}
        // over mDNS. Returns a handle id; JS wraps it as { id, stop() }.
        // Browse: long-lived NWBrowser that fires per-handle channel pushes
        // ("bonjour:browse:<id>") with the full current result-set on every
        // change. JS sd.bonjour.browse(type) returns { id, subscribe(fn),
        // stop() } that wires the same channel name to the standard signal
        // machinery. Permission: "bonjour". macOS 15+ surfaces a Local
        // Network privacy prompt on first publish/browse; Network.framework
        // raises it — we don't preflight.
        .custom("bonjour.publish", permission: "bonjour") { bridge, body, requestId in
            // IPC envelope's `type` key is reserved for primitive dispatch
            // ("bonjour.publish"), so the service type travels under
            // `serviceType` — matches the caffeinate.assert/assertionType
            // workaround elsewhere in this file.
            let name = body["name"] as? String ?? ""
            let type = body["serviceType"] as? String ?? ""
            let port = UInt16((body["port"] as? Int) ?? 0)
            let txt  = body["txt"] as? [String: String]
            guard !name.isEmpty, !type.isEmpty, port > 0,
                  let handle = Bonjour.publish(name: name, type: type, port: port, txt: txt) else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            let id = bridge.nextBonjourId
            bridge.nextBonjourId += 1
            bridge.bonjourPublishHandles[id] = Token { handle.stop() }
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("bonjour.publish.stop", permission: "bonjour", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t  = b.bonjourPublishHandles.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },
        .custom("bonjour.browse.start", permission: "bonjour") { bridge, body, requestId in
            // serviceType (not `type`) for the same envelope-collision reason
            // documented on bonjour.publish above.
            let type = body["serviceType"] as? String ?? ""
            guard !type.isEmpty else {
                bridge.respond(requestId: requestId, value: NSNull()); return
            }
            let id = bridge.nextBonjourId
            bridge.nextBonjourId += 1
            let channel = "bonjour:browse:\(id)"
            let browser = Bonjour.Browser(type: type) { [weak bridge] entries in
                guard let bridge = bridge else { return }
                let json = Bridge.jsonify(entries)
                bridge.push(channel: channel, json: json)
            }
            bridge.bonjourBrowseHandles[id] = Token { browser.stop() }
            bridge.respond(requestId: requestId, value: id)
        },
        .syncBridge("bonjour.browse.stop", permission: "bonjour", denyValue: false) { b, body in
            guard let id = body["id"] as? Int,
                  let t  = b.bonjourBrowseHandles.removeValue(forKey: id) else { return false }
            t.cancel()
            return true
        },

        // Tunable poll cadence. JS calls `sd.sensors.subscribe(fn, { interval })`
        // → api.js forwards this IPC → the bridge gates the per-stack fanout for
        // the matching channel to at most one push every `interval` seconds. The
        // native observer keeps polling at its base rate (2s for sensors / host /
        // display); only the JSON + evaluateJavaScript hop is throttled. interval
        // <= 0 (or null) clears the gate. No permission gate — telling your own
        // stack to push less often is always safe.
        .syncBridge("channel.setInterval", permission: nil, denyValue: false) { b, body in
            guard let name = body["name"] as? String else { return false }
            if let interval = body["interval"] as? Double, interval > 0 {
                b.channelIntervals[name] = interval
                // Touchdevice's native coalescer rate is normally fixed at
                // 30Hz; for that one channel, slowing the per-stack push
                // is wasted work because we still re-poll the device every
                // 33ms. Route the request down to the observer so the
                // coalescer matches. Last-writer-wins across stacks for
                // now — fine for the common case (one gesture stack).
                if name == "touchdevice" {
                    TouchDeviceObserver.shared.setCoalesceInterval(ms: Int(interval))
                }
            } else {
                b.channelIntervals.removeValue(forKey: name)
                if name == "touchdevice" {
                    // Restore default 30Hz when the gate is cleared.
                    TouchDeviceObserver.shared.setCoalesceInterval(ms: 33)
                }
            }
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

    /// Dispatch to a JS global handler with pre-formatted JS argument
    /// strings. `handler` is the global property name (e.g. "__sd_fs_event",
    /// "onHotkey_foo", a user-supplied callback name); we look it up via
    /// `globalThis[<jsString-of-handler>]` so handler names with quotes or
    /// other tricky characters can't break out. Each entry in `args` is
    /// already valid JS (a JSON blob, a numeric literal, a string literal)
    /// and is joined with commas.
    private func fireGlobal(handler: String, args: [String] = []) {
        guard let webView = webView else { return }
        let h = Bridge.jsString(handler)
        let joined = args.joined(separator: ", ")
        let script = "globalThis[\(h)] && globalThis[\(h)](\(joined));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func dispatchFsEvents(watchId: Int, events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let payload = events.map { ev -> [String: Any] in
            ["path": ev.path, "kind": FSWatch.kindFor(flags: ev.flags)]
        }
        fireGlobal(handler: "__sd_fs_event", args: ["\(watchId)", Bridge.jsonify(payload)])
    }

    /// Pump a menubar-item click / pick / etc. back to JS. The JS-side proxy
    /// in api.js (sd.menubar.addItem) routes this to the stack's callbacks.
    fileprivate func dispatchMenubarEvent(itemId: Int, type: String, payload: Any?) {
        let payloadJson = payload.map { Bridge.jsonify($0) } ?? "null"
        fireGlobal(handler: "__sd_menubar_event",
                   args: ["\(itemId)", Bridge.jsString(type), payloadJson])
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("stackd: \(s)\n".utf8))
    }

    // (permission, channel) tuples driving replayState. Same keys lastState
    // is written under in startXxx — adding a new channel here is the only
    // wiring needed for "ready" replay to find it.
    private static let replayTable: [(permission: String, channel: String)] = [
        ("battery",     "battery"),
        ("mouse",       "mouse"),
        ("app",         "frontApp"),
        ("windows",     "focusedWindow"),
        ("windows",     "windowsAll"),
        ("windows",     "windowsChanged"),
        ("appearance",  "appearance"),
        ("input",       "inputLayout"),
        ("net",         "netWifi"),
        ("net",         "netLan"),
        ("net",         "netPath"),
        ("net",         "netThroughput"),
        ("audio",       "audioOutput"),
        ("audio",       "audioInput"),
        ("display",     "displays"),
        ("media",       "media"),
        ("calendar",    "calendarChanged"),
        ("menubar",     "menubarItems"),
        ("pasteboard",  "pasteboard"),
        ("apps",        "apps"),
        ("spaces",      "spaces"),
        ("caffeinate",  "caffeinate"),
        ("sensors",     "sensors"),
        ("location",    "location"),
        ("usb",         "usb"),
        ("camera",      "camera"),
        ("host",        "hostLoad"),
        ("touchdevice", "touchdevice"),
        ("displayLink", "displayLink"),
        // F15: granular per-event-type channels split out of the legacy
        // focusedWindow / frontApp pumps. Same permissions as the union
        // channels so stacks declaring "app" / "windows" pick them up
        // automatically.
        ("app",         "appActivated"),
        ("windows",     "focusedChanged"),
        ("windows",     "titleChanged"),
    ]

    private func replayState() {
        for (permission, channel) in Bridge.replayTable {
            guard permissions.contains(permission),
                  let json = lastState[channel] else { continue }
            push(channel: channel, json: json)
        }
    }

    /// Wire a snapshot-driven channel: prime once, then refire on every
    /// observer tick. Returning nil from `snapshot` skips the push — matches
    /// the "no data yet" cases (host.load before its first diff, touchdevice
    /// before the first frame, displayLink before vsync).
    ///
    /// Dedupe via lastState[name]: re-emitting an identical JSON blob is
    /// pure overhead (WebKit roundtrip + signal subscribers re-running), and
    /// most observers (Battery, Audio, Display) fire on broad notifications
    /// where the underlying snapshot often hasn't actually changed.
    private func startChannel(
        name: String,
        observer: RefCountedObserver,
        snapshot: @escaping () -> Any?
    ) {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            // Honor sd.channel.setInterval-set cadence: if a stack asked
            // for a slower fanout on this channel, skip ticks that arrive
            // earlier than the requested interval. Native polling rate is
            // unchanged — this just gates the per-stack JSON + JS round-trip.
            if let interval = self.channelIntervals[name],
               let last = self.lastChannelPushedAt[name],
               Date().timeIntervalSince(last) < interval {
                return
            }
            guard let value = snapshot() else { return }
            let json = Bridge.jsonify(value)
            guard json != self.lastState[name] else { return }
            self.lastState[name] = json
            self.lastChannelPushedAt[name] = Date()
            self.push(channel: name, json: json)
        }
        pushFn()
        scope.adopt(observer.subscribe(pushFn))
    }

    private func startBattery() {
        startChannel(name: "battery", observer: BatteryObserver.shared) {
            // Additive: existing `percent` / `charging` keys keep their shape
            // and position; the deep IOKit readings (IOPS dict + AppleSmart-
            // Battery IORegistry) follow as optional fields. Each nil-able
            // value goes through `?? NSNull()` so the JSON serializer emits
            // `null` rather than dropping the key — stack authors see the
            // same field shape on desktops (no battery) and on MacBooks
            // alike.
            [
                "percent": Battery.percent(),
                "charging": Battery.isCharging(),
                "cycles": Battery.cycles() as Any? ?? NSNull(),
                "health": Battery.health() as Any? ?? NSNull(),
                "designCapacity": Battery.designCapacity() as Any? ?? NSNull(),
                "maxCapacity": Battery.maxCapacity() as Any? ?? NSNull(),
                "currentCapacity": Battery.currentCapacity() as Any? ?? NSNull(),
                "amperage": Battery.amperage() as Any? ?? NSNull(),
                "voltage": Battery.voltage() as Any? ?? NSNull(),
                "timeRemaining": Battery.timeRemaining() as Any? ?? NSNull(),
                "isFinishingCharge": Battery.isFinishingCharge() as Any? ?? NSNull(),
            ]
        }
    }

    private func startMouse() {
        // Truncate to Int for the dedupe — sub-pixel jitter would otherwise
        // push every tick. Matches the original ad-hoc interpolation.
        // Enrich with the containing display so stacks don't reimplement the
        // O(displays) forPoint loop on every tick. Display.forPoint is cheap
        // (NSScreen.screens iteration, no DDC); on a typical 1-2 display
        // setup this is sub-microsecond.
        startChannel(name: "mouse", observer: MouseObserver.shared) {
            let p = Mouse.location()
            var payload: [String: Any] = ["x": Int(p.x), "y": Int(p.y)]
            if let d = Display.forPoint(p) { payload["display"] = d }
            return payload
        }
    }

    private func startAppearance() {
        startChannel(name: "appearance", observer: AppearanceObserver.shared) {
            Appearance.current()
        }
    }

    private func startInput() {
        startChannel(name: "inputLayout", observer: InputObserver.shared) {
            Input.currentLayout()
        }
    }

    // Multi-channel: one observer (NetworkObserver) feeds three sd.net.*
    // channels. Each branch independently dedupes against lastState so a wifi
    // SSID change doesn't refire lan / path. Keeps its bespoke shape rather
    // than splitting into three observers — the underlying NWPathMonitor is
    // shared.
    private func startNetwork() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let lanJson = Bridge.jsonify(NetLAN.current())
            if lanJson != self.lastState["netLan"] {
                self.lastState["netLan"] = lanJson
                self.push(channel: "netLan", json: lanJson)
            }
            let wifiJson = Bridge.jsonify(NetWiFi.current())
            if wifiJson != self.lastState["netWifi"] {
                self.lastState["netWifi"] = wifiJson
                self.push(channel: "netWifi", json: wifiJson)
            }
            // sd.net.path — derived from the same NWPathMonitor (no parallel
            // monitor). NetworkObserver caches the latest NWPath; the priming
            // fire() before any path callback can land sees nil, so skip the
            // push until the first real update arrives. That matches
            // sd.host.load / sd.touchdevice's "no data yet" handling.
            if let path = NetworkObserver.shared.latestPath {
                let pathJson = Bridge.jsonify(NetPath.snapshot(from: path))
                if pathJson != self.lastState["netPath"] {
                    self.lastState["netPath"] = pathJson
                    self.push(channel: "netPath", json: pathJson)
                }
            }
        }
        pushFn()
        scope.adopt(NetworkObserver.shared.subscribe(pushFn))
    }

    // Aggregate throughput across non-loopback interfaces. Replaces the
    // `netstat -ib` setInterval(1s) in bar/items/throughput.js — observer
    // owns the diff math + previous-sample cache so multiple stack
    // subscribers all read the same rate per tick (the previous JS-side
    // version recomputed per stack, drifting its baseline each call).
    private func startNetworkThroughput() {
        startChannel(name: "netThroughput", observer: NetworkThroughputObserver.shared) {
            NetworkThroughputObserver.shared.current
        }
    }

    private func startAudio() {
        startChannel(name: "audioOutput", observer: AudioObserver.shared) {
            Audio.current()
        }
        // Mirror channel for the default input device. Separate observer
        // because each AudioObserver / AudioInputObserver owns its own
        // listener-block refs and default-device selector — splitting keeps
        // an input device change from re-firing the output channel and vice
        // versa.
        startChannel(name: "audioInput", observer: AudioInputObserver.shared) {
            Audio.currentInput()
        }
    }

    private func startDisplay() {
        startChannel(name: "displays", observer: DisplayObserver.shared) {
            Display.all()
        }
    }

    // Async snapshot: Media.nowPlaying delivers the dict on a background
    // queue, so the dedupe/push hop has to land on main itself. Doesn't fit
    // the synchronous startChannel helper.
    private func startMedia() {
        let pushFn: () -> Void = { [weak self] in
            Media.nowPlaying { info in
                guard let self = self else { return }
                let json = info.map { Bridge.jsonify($0) } ?? "null"
                DispatchQueue.main.async {
                    if json == self.lastState["media"] { return }
                    self.lastState["media"] = json
                    self.push(channel: "media", json: json)
                }
            }
        }
        // Initial hydration runs off-main: Media.nowPlaying's MediaRemote-
        // absent path AND the scripted-fallback path both block synchronously
        // (Process.run + waitUntilExit, ~200-600ms cold) on the calling
        // queue. startMedia runs during stack load on main — inline pushFn()
        // would stutter every stack with `media` perm on a Spotify-active
        // session. Hop to utility; the dedupe/push still lands on main.
        DispatchQueue.global(qos: .utility).async { pushFn() }
        scope.adopt(MediaObserver.shared.subscribe(pushFn))
    }

    // Store-change ping channel: EKEventStoreChanged fires when any app
    // (Calendar.app, Reminders, an MDM sync, this daemon's own createEvent)
    // writes to the EventKit database. Apple's docs note the notification's
    // userInfo dict is always empty — there's no delta to ship. We push a
    // monotonic timestamp so the channel's dedupe (lastState string compare)
    // doesn't suppress repeat changes; JS subscribers re-fetch on every
    // signal. Cheap fire-and-forget for stacks that want to keep an agenda
    // view live without polling.
    private func startCalendar() {
        startChannel(name: "calendarChanged", observer: CalendarObserver.shared) {
            // Payload is just a fresh timestamp so re-emission dedupe never
            // suppresses a real store change. JS doesn't read the value —
            // the channel is treated as a bell, not a snapshot.
            ["ts": Date().timeIntervalSince1970]
        }
    }

    // Privacy — polled 2s observer pushes the cross-categorical
    // "what's recording" snapshot whenever the active set changes.
    // startChannel's lastState dedupe handles the steady-state case
    // (nothing recording → same payload tick after tick → no push).
    // The snapshot itself reads AVCaptureDevice + CoreAudio property
    // APIs; neither triggers a TCC prompt.
    private func startPrivacy() {
        startChannel(name: "privacy", observer: PrivacyObserver.shared) {
            Privacy.recording()
        }
    }

    // sd.menubar.observe — AX-walk the menubar every 2s, diff against the
    // last push, fire on change. AX has no reliable push notification for
    // status-item add/remove, so this is poll-and-diff via startChannel's
    // built-in lastState dedupe. Cadence is tunable per-stack via
    // sd.channel.setInterval. The MenubarItemsObserver keeps a per-PID
    // owner-name cache alive across polls so the NSRunningApplication
    // lookup (the slow part) doesn't repeat for steady-state items.
    private func startMenubarItems() {
        startChannel(name: "menubarItems", observer: MenubarItemsObserver.shared) {
            MenubarItemsObserver.shared.snapshot()
        }
    }

    private func startPasteboard() {
        startChannel(name: "pasteboard", observer: PasteboardObserver.shared) {
            // The signal payload is the current string (or null) — that's what
            // every consumer (CloudPad URL copy, Palette clipboard verbs,
            // Muse paste-at-caret) actually wants.
            let s = Pasteboard.getString() ?? ""
            return ["text": s, "changeCount": Pasteboard.changeCount]
        }
    }

    // Custom: snapshot has a side effect (computing the apps.changed delta
    // vs lastAppsByBundle) and emits a second channel. Doesn't fit
    // startChannel.
    private func startApps() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let snapshot = Apps.running()
            let json = Bridge.jsonify(snapshot)
            if json == self.lastState["apps"] { return }

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
            self.lastState["apps"] = json
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
        startChannel(name: "spaces", observer: SpacesObserver.shared) {
            Spaces.all()
        }
    }

    private func startCaffeinate() {
        startChannel(name: "caffeinate", observer: CaffeinateObserver.shared) {
            Caffeinate.snapshot()
        }
    }

    private func startDisplayLink() {
        // First-tick nil (vsync hasn't landed yet) → snapshot returns nil →
        // startChannel skips the push.
        startChannel(name: "displayLink", observer: DisplayLinkObserver.shared) {
            DisplayLink.snapshot()
        }
    }

    private func startSensors() {
        startChannel(name: "sensors", observer: SensorsObserver.shared) {
            Sensors.snapshot()
        }
    }

    private func startLocation() {
        // snapshot() is nil until authorization + first fix; emit an explicit
        // "null" so the JS channel sees that initial state instead of staying
        // un-fired. Wrap in [NSNull()] sentinel to flow through jsonify as
        // "null".
        startChannel(name: "location", observer: LocationObserver.shared) {
            return Location.snapshot() ?? NSNull()
        }
    }

    private func startUSB() {
        startChannel(name: "usb", observer: USBObserver.shared) {
            USB.snapshot()
        }
    }

    private func startCamera() {
        startChannel(name: "camera", observer: CameraObserver.shared) {
            Camera.snapshot()
        }
    }

    private func startHost() {
        // First tick returns nil — CPU fractions need a prior sample to diff
        // against. startChannel skips the push; the next 2s tick has the value.
        startChannel(name: "hostLoad", observer: HostObserver.shared) {
            Host.loadSnapshot()
        }
    }

    private func startTouchDevice() {
        // No-frame state (untouched trackpad before first event) → nil →
        // startChannel skips. JS sees the channel stay at its null initial.
        startChannel(name: "touchdevice", observer: TouchDeviceObserver.shared) {
            TouchDevice.snapshot()
        }
    }

    // Dual-observer: NSWorkspace activations + per-pid FrontmostWindowObserver
    // for within-app focus/title changes. Emits up to six channels per tick:
    //   - frontApp / focusedWindow / windowsAll (legacy union — backward compat)
    //   - appActivated / focusedChanged / titleChanged (granular per-event-type,
    //     per F15)
    // Gated on includeApp / includeWindows flags. Doesn't fit startChannel's
    // single-channel shape.
    private func startWorkspace(includeApp: Bool, includeWindows: Bool) {
        // Per-channel dedupe-and-push helpers. Each granular channel reuses
        // lastState so re-firing the same payload (common when AX nudges
        // multiple times for one focus change) doesn't traverse WebKit
        // unnecessarily.
        let pushAppActivated: () -> Void = { [weak self] in
            guard let self = self, let app = App.frontmostApp() else { return }
            let json = Bridge.jsonify(app)
            if json == self.lastState["appActivated"] { return }
            self.lastState["appActivated"] = json
            self.push(channel: "appActivated", json: json)
        }
        let pushFocusedChanged: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Windows.focused().map(Bridge.jsonify) ?? "null"
            if json == self.lastState["focusedChanged"] { return }
            self.lastState["focusedChanged"] = json
            self.push(channel: "focusedChanged", json: json)
        }
        let pushTitleChanged: () -> Void = { [weak self] in
            guard let self = self, let w = Windows.focused() else { return }
            // Small payload — id, app, title, pid. Keeps the channel narrow
            // so stacks that only care about title rename don't pay the
            // whole focusedWindow dict on every keystroke in a renaming field.
            let payload: [String: Any] = [
                "id":    w["id"]    as Any? ?? NSNull(),
                "app":   w["app"]   as Any? ?? "",
                "title": w["title"] as Any? ?? "",
                "pid":   w["pid"]   as Any? ?? 0
            ]
            let json = Bridge.jsonify(payload)
            if json == self.lastState["titleChanged"] { return }
            self.lastState["titleChanged"] = json
            self.push(channel: "titleChanged", json: json)
        }
        // Legacy union channel: refire focusedWindow / windowsAll whenever
        // either focusedChanged or titleChanged fires. Stacks still on
        // sd.windows.focused see the same shape they always did.
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            if includeApp, let app = App.frontmostApp() {
                let json = Bridge.jsonify(app)
                if json != self.lastState["frontApp"] {
                    self.lastState["frontApp"] = json
                    self.push(channel: "frontApp", json: json)
                }
            }
            if includeWindows {
                let json = Windows.focused().map(Bridge.jsonify) ?? "null"
                if json != self.lastState["focusedWindow"] {
                    self.lastState["focusedWindow"] = json
                    self.push(channel: "focusedWindow", json: json)
                }
                let snapshot = Windows.all()
                let allJson = Bridge.jsonify(snapshot)
                if allJson != self.lastState["windowsAll"] {
                    self.lastState["windowsAll"] = allJson
                    self.push(channel: "windowsAll", json: allJson)
                    // Compute the diff parallel to sd.apps.changed so
                    // consumers (windowscape / undoclose / framemaster) can
                    // pay diff-size instead of full-list-size. Suppress the
                    // first-tick `added: everything` noise — that's the
                    // same data sd.windows.all already delivered.
                    let delta = Bridge.windowsDelta(snapshot: snapshot, previous: self.lastWindowsByID)
                    self.lastWindowsByID = delta.nowByID
                    let primed = (self.lastState["windowsChanged"] ?? "").isEmpty == false
                    if primed && (!delta.added.isEmpty || !delta.removed.isEmpty || !delta.changed.isEmpty) {
                        let payload: [String: Any] = [
                            "added":   delta.added,
                            "removed": delta.removed,
                            "changed": delta.changed
                        ]
                        let deltaJson = Bridge.jsonify(payload)
                        self.lastState["windowsChanged"] = deltaJson
                        self.push(channel: "windowsChanged", json: deltaJson)
                    } else if !primed {
                        // Prime the marker so subsequent ticks know they
                        // can emit. Marker value doesn't matter — only
                        // its non-empty presence is checked above.
                        self.lastState["windowsChanged"] = "primed"
                    }
                }
            }
        }
        // Install granular per-event-type callbacks. FrontmostWindowObserver
        // is multi-subscriber: append our handlers, scope-drain the tokens
        // on stack unload. The previous design used single-slot callbacks
        // and the LAST Bridge to set them won — every other stack's
        // focusedChanged / titleChanged silently stopped firing.
        if includeApp {
            scope.adopt(FrontmostWindowObserver.shared.appendAppActivated(pushAppActivated))
        }
        if includeWindows {
            scope.adopt(FrontmostWindowObserver.shared.appendFocusedChanged(pushFocusedChanged))
            scope.adopt(FrontmostWindowObserver.shared.appendTitleChanged(pushTitleChanged))
        }
        // Prime each granular channel so subscribers don't wait for the first
        // AX nudge to see a value.
        if includeApp { pushAppActivated() }
        if includeWindows {
            pushFocusedChanged()
            pushTitleChanged()
        }
        pushFn()
        scope.adopt(FrontmostAppObserver.shared.subscribe(pushFn))
        if includeWindows {
            scope.adopt(FrontmostWindowObserver.shared.subscribe(pushFn))
        }
    }

    private func fireHotkey(callback: String) {
        // Strip embedded quotes defensively — the callback comes from a stack
        // manifest, and `onHotkey_<callback>` is interpolated into the lookup
        // name. fireGlobal escapes the resulting key for us via jsString.
        let safe = callback.replacingOccurrences(of: "\"", with: "")
        fireGlobal(handler: "onHotkey_\(safe)")
    }

    private func fireEventTap(callback: String, type: CGEventType, event: CGEvent) {
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
        // mouseMoved + the dragged variants carry frame-to-frame deltas in the
        // CGEvent's mouseEventDeltaX/Y fields. Consumers that integrate motion
        // (EdgeHopper accumulates these to detect cursor "punch-through" at
        // screen edges) need them — sampling location() at JS rate misses
        // sub-frame motion.
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            payload["deltaX"] = event.getDoubleValueField(.mouseEventDeltaX)
            payload["deltaY"] = event.getDoubleValueField(.mouseEventDeltaY)
        default: break
        }
        if type.rawValue == Gesture.cgEventType.rawValue,
           let g = Gesture.describe(cgEvent: event) {
            for (k, v) in g { payload[k] = v }
        }

        fireGlobal(handler: "onTap_\(callback)", args: [Bridge.jsonify(payload)])
    }

    /// Escape an arbitrary string into a JS string literal. JSONSerialization
    /// handles the corner cases (quotes, backslashes, control chars) that
    /// naive replacement would miss.
    fileprivate static func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
           let out = String(data: data, encoding: .utf8) {
            return out
        }
        return "\"\""
    }

    private func push(channel: String, json: String) {
        guard let webView = webView else { return }
        // Trace every channel push when STACKD_RPC_DEBUG=1. Same throttle
        // shape as the RPC tracer above. Off by default — high-rate
        // channels (sd.mouse, sd.windows.all) would otherwise spam stderr.
        if Bridge.rpcTraceEnabled {
            let now = Date().timeIntervalSince1970
            let lastLogged = Bridge.lastPushLogged[channel] ?? 0
            if now - lastLogged >= Bridge.pushLogThrottleSec {
                Bridge.lastPushLogged[channel] = now
                let preview = json.count > 120 ? String(json.prefix(117)) + "..." : json
                FileHandle.standardError.write(Data("stackd: push \(channel) (\(json.count)B) \(preview)\n".utf8))
            }
        }
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

    /// Pure delta computation between two window snapshots. Identity is
    /// CGWindowID (recycled at most across reboots, monotonic within a
    /// session). The "changed" detector compares only the mutable fields
    /// consumers actually care about — title, frame.{x,y,w,h} — so a
    /// jsonify round-trip can't false-fire on Swift dict key-order noise.
    /// Returns the new id-keyed cache too so the caller doesn't rebuild it.
    static func windowsDelta(snapshot: [[String: Any]], previous: [Int: [String: Any]])
        -> (added: [[String: Any]], removed: [[String: Any]], changed: [[String: Any]], nowByID: [Int: [String: Any]])
    {
        var nowByID: [Int: [String: Any]] = [:]
        for w in snapshot {
            if let id = w["id"] as? Int { nowByID[id] = w }
        }
        var added:   [[String: Any]] = []
        var removed: [[String: Any]] = []
        var changed: [[String: Any]] = []
        for (id, w) in nowByID {
            if let prev = previous[id] {
                let t1 = (prev["title"] as? String) ?? ""
                let t2 = (w["title"]    as? String) ?? ""
                let f1 = (prev["frame"] as? [String: Any]) ?? [:]
                let f2 = (w["frame"]    as? [String: Any]) ?? [:]
                let same = t1 == t2 &&
                    (f1["x"] as? Int) == (f2["x"] as? Int) &&
                    (f1["y"] as? Int) == (f2["y"] as? Int) &&
                    (f1["w"] as? Int) == (f2["w"] as? Int) &&
                    (f1["h"] as? Int) == (f2["h"] as? Int)
                if !same { changed.append(w) }
            } else {
                added.append(w)
            }
        }
        for (id, w) in previous where nowByID[id] == nil {
            removed.append(w)
        }
        return (added, removed, changed, nowByID)
    }

    static func jsonify(_ obj: Any) -> String {
        // .fragmentsAllowed lets us serialize bare scalars (Bool/Int/String) at
        // the top level — required for imperative API responses like
        // setVolume → true, defaults.read → "value".
        // .sortedKeys guarantees deterministic key order so the channel
        // dedupe (string-compare against lastState[channel]) doesn't
        // false-mismatch when two code paths build the same dict in
        // different insertion orders (e.g. MediaRemote vs scripted-fallback
        // building the media snapshot).
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed, .sortedKeys]),
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
