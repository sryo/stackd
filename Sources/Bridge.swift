import WebKit
import IOKit.pwr_mgt
import CoreAudio  // AudioDeviceID — used by sd.audio.setDefaultDevice

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    // Widened from fileprivate to internal so BridgeSQLite.swift's
    // sqlite.open closure can build the default per-stack data/ path.
    var stackId: String = ""
    // Install-once latch for the sd-on:click hover observer (BridgeWindow's
    // window.setInteractiveRects) — first call registers the daemon-internal
    // mouseMoved gate, later calls only update its rects. The token drains
    // with the scope on unload like every other observer.
    var interactiveHoverInstalled = false
    private var permissions: [String] = []
    // Per-channel JSON dedupe cache, keyed by the channel name used in
    // push(channel:json:). Every startXxx() reads + writes via this dict so
    // adding a new channel doesn't require declaring another `lastXxx` field.
    // Widened from private to internal so BridgeChannels.swift's startXxx()
    // starters can dedupe against it.
    var lastState: [String: String] = [:]
    // Parsed snapshot used to compute the sd.apps.changed delta — keyed by
    // bundleId because pids recycle but bundleIds are stable across launches.
    // Not a string cache, so it sits next to lastState rather than inside it.
    // Widened from private to internal so BridgeChannels.swift's startApps()
    // can compute the delta.
    var lastAppsByBundle: [String: [String: Any]] = [:]
    // Same shape for sd.windows.changed — keyed by CGWindowID. Widened from
    // private to internal so BridgeChannels.swift's startWorkspace() can
    // compute the delta.
    var lastWindowsByID: [Int: [String: Any]] = [:]
    // First-tick suppression for windows.changed (and apps.changed had this
    // implicitly via lastAppsByBundle being empty). Set true after the first
    // windowsAll push lands; only then do we start emitting deltas, so the
    // initial "every window added" noise — duplicating sd.windows.all — is
    // suppressed. Boolean flag instead of an in-lastState marker because
    // replayState pushes lastState[channel] verbatim into JS via
    // `__sd_push("name", <RAW>)`, and any non-JSON marker like "primed"
    // becomes an undefined-identifier ReferenceError.
    // Primed flags + delta caches below widened from private to internal so
    // BridgeChannels.swift's starters can read/write them.
    var windowsChangedPrimed: Bool = false
    // Same shape again for sd.displays.changed — keyed by displayID.
    var lastDisplaysByID: [Int: [String: Any]] = [:]
    var displaysChangedPrimed: Bool = false
    // Same shape again for sd.menubar.changed — keyed by "<owner>|<title>"
    // since menubar items have no stable id. owner+title is the closest
    // thing to an identity (a third-party icon doesn't usually rename
    // itself mid-session; if it does the diff fires removed+added once).
    var lastMenubarByKey: [String: [String: Any]] = [:]
    var menubarChangedPrimed: Bool = false
    // Widened from private to internal so BridgeStorage.swift's settings.*
    // closures can read/write the per-stack StackSettings.
    var settings: StackSettings?
    // Widened from private to internal so BridgeFS.swift's fs.watch.start /
    // fs.watch.stop closures can mint and release watch handles.
    var fsWatches: [Int: FSWatch] = [:]
    // Widened to internal so the bang.handle primitive can insert into it
    // when sd.bang.declare(name).on() runs in JS — auto-registration so
    // stacks don't have to also list the bang name in their manifest's
    // `handles` array.
    var handlesBangs: Set<String> = []
    // Set in `startWorkspace` when the stack declares `windows` / `app`.
    // AppDelegate's window-lifecycle handlers call `pumpWindowsList()` on
    // every Bridge so each create / destroy / title-change refreshes the
    // sd.windows.all channel — without this, the channel only re-fires
    // on focus changes and a background-app window closing never reaches
    // the stack's state. nil for stacks that don't need it.
    // Widened from fileprivate to internal so BridgeChannels.swift's
    // startWorkspace() can install the pump.
    var windowsListPump: (() -> Void)?
    // Widened from private to internal so BridgeAX.swift's ax.* closures
    // can read/release handles via the per-Bridge HandleStore.
    let axHandles = AX.HandleStore()
    // Outstanding sd.menubar.suppress() tokens (LIFO). sd.menubar.restore()
    // pops one. Anything left at unload is drained by scope.
    // Widened from private to internal so BridgeMenubar.swift's
    // menubar.suppress / .restore closures can push/pop tokens.
    var menubarSuppressions: [Token] = []
    // Outstanding sd.desktop.hideIcons() holds (LIFO), popped by showIcons()
    // and drained by scope at unload, same shape as menubarSuppressions.
    var desktopIconHolds: [Token] = []
    // Ordering for eval(_:in:) — see EvalOrderGate.
    private var evalGate = EvalOrderGate()
    private let evalGateLock = NSLock()
    // Scripts sent to the page and not yet evaluated — see send(_:).
    private let outbox = EvalOutbox()

    // Native handles JS primitives mint for this stack, keyed by the id JS
    // gets back. The scope drain releases whatever is still held at unload
    // (see start(manifest:)), so a reload never leaks registrations.
    //
    // NSStatusItems (sd.menubar.addItem); unload removes them from the bar.
    let statusItems = HandleTable<StatusItemHandle>()
    // Carbon hotkeys (sd.hotkey.bind). The JS side keeps its own map keyed
    // by the same id so __sd_hotkey_fire can find the callback.
    let hotkeyTokens = HandleTable<Token>()
    // DistributedNotificationCenter observers (sd.broadcasts.observe).
    let broadcastTokens = HandleTable<Token>()
    // Per-scheme SchemeRouter subscribers (sd.urlhandler.register).
    let urlHandlerTokens = HandleTable<Token>()
    // Window-tracked overlays (sd.overlay.attach) and free-region overlays
    // (sd.overlay.region) share ids so they never collide. Each tracked
    // overlay owns a borderless NSPanel + WKWebView and stops its own
    // reposition driving on detach; regionFollowTokens holds a region's
    // cursor-follow vsync subscription.
    let overlayHandles: HandleTable<OverlayHandle>
    let regionOverlayHandles: HandleTable<RegionOverlayHandle>
    let regionFollowTokens = HandleTable<Token>()
    // HTTP servers (sd.httpserver.serve) and the requests waiting for
    // sd.httpserver.respond(), whose value is the connection's completion.
    // One id space, so a server id never equals a request id.
    let httpServerTokens: HandleTable<Token>
    let pendingHttpResponses: HandleTable<(HTTPResponse) -> Void>
    // Bonjour advertisements (NWListener) and browsers (NWBrowser), one id
    // space. A browser pushes on "bonjour:browse:<id>".
    let bonjourPublishHandles: HandleTable<Token>
    let bonjourBrowseHandles: HandleTable<Token>
    // Continuous Spotlight queries, pushed on "spotlight:subscribe:<id>".
    let spotlightLiveHandles = HandleTable<Token>()
    // Camera captures, pushed on "camera:stream:<id>"; unload stops them so
    // a reload doesn't leave the camera LED on.
    let cameraStreamHandles = HandleTable<Token>()
    // sd.windows.stream() timers, pushed on "windows:stream:<id>".
    let windowStreamHandles = HandleTable<Token>()
    // Speech recognizers + their audio taps, pushed on "speech:listen:<id>";
    // unload stops them so a reload doesn't strand the microphone.
    let speechListenHandles = HandleTable<Token>()
    // SQLite connections this stack opened. The ids come from the
    // process-wide SQLite.HandleStore; the ownership is stack-scoped.
    var sqliteHandles: Set<Int> = []
    // Streamed subprocesses (sd.proc.stream); unload SIGTERMs any still
    // running. The terminationHandler still fires after unload.
    let procStreamHandles = HandleTable<ProcStreamHandle>()
    // IOPMAssertions (sd.caffeinate.assert), so a forgotten wake-lock
    // doesn't outlive the stack that took it.
    let caffeinateAssertions = HandleTable<IOPMAssertionID>()
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
    // Widened from fileprivate to internal so BridgeChannels.swift's
    // startChannel() can read the gate (channel.setInterval writes stay here).
    var channelIntervals: [String: TimeInterval] = [:]
    var lastChannelPushedAt: [String: Date] = [:]
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

    // Single source of truth for the channel → JS-path → permission table,
    // injected as `window.__sd_channels` BEFORE api.js executes so the
    // runtime's template engine can build its `__sdSignalPaths` map from
    // the same Swift `Channels.all` list that drives `replayState()`.
    //
    // .atDocumentStart so it lands before `runtimeLoaderScript`'s dynamic
    // import resolves the runtime module. Without the channels global,
    // api.js falls back to an empty placeholder lookup and templates lose
    // dependency tracking — there's a defensive console.warn in api.js if
    // the global is missing, so a misconfigured runtime fails loud.
    private static let channelsBootstrapScript: WKUserScript = {
        let source = "window.__sd_channels = \(Channels.jsBootstrapJSON);"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    /// Minimal CSS reset injected by default. `:where()` gives every selector
    /// inside zero specificity so any stack rule (specificity ≥ (0,0,1)) wins
    /// without authors having to override or know about cascade order. Authors
    /// opt out via `"reset": false` in the manifest when they want full
    /// control of the root box. `user-select:none` is inheritable, so applying
    /// it on html/body covers every descendant — stack chrome is interactive
    /// UI, not document content. Text-editor / notes-style stacks override.
    static let resetStyle = ":where(html,body){margin:0;padding:0;background:transparent;-webkit-user-select:none;user-select:none}"

    init(webView: WKWebView, screen: NSScreen? = nil, screenIndex: Int = 0, padding: Double = 0, injectReset: Bool = true) {
        self.webView = webView
        let overlayIds = HandleIds()
        overlayHandles = HandleTable(ids: overlayIds)
        regionOverlayHandles = HandleTable(ids: overlayIds)
        let httpIds = HandleIds()
        httpServerTokens = HandleTable(ids: httpIds)
        pendingHttpResponses = HandleTable(ids: httpIds)
        let bonjourIds = HandleIds()
        bonjourPublishHandles = HandleTable(ids: bonjourIds)
        bonjourBrowseHandles = HandleTable(ids: bonjourIds)
        super.init()
        let ucc = webView.configuration.userContentController
        ucc.add(self, name: "sd")
        ucc.add(self, name: "log")
        ucc.addUserScript(Bridge.consoleHookScript)
        ucc.addUserScript(Bridge.channelsBootstrapScript)
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
        // CSS reset — wraps every rule in `:where()` AND inserts the <style>
        // BEFORE the head's first child (rather than appending). Belt-and-
        // suspenders: even at equal specificity (0,0,1), declaration order
        // makes the stack rule win because it's parsed second. The previous
        // `appendChild` left the reset AFTER the stack's <link>, so any
        // (0,0,1) stack rule lost to the reset on cascade order — exactly
        // wrong for "reset is a sensible default the stack should easily
        // override." Opposite story from the padding block above on purpose.
        if injectReset {
            let source = """
            (function(){
              var s = document.createElement('style');
              s.setAttribute('data-sd', 'reset');
              s.textContent = \(Bridge.jsonify(Bridge.resetStyle));
              var head = document.head || document.documentElement;
              if (head.firstChild) head.insertBefore(s, head.firstChild);
              else head.appendChild(s);
            })();
            """
            let inject = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            ucc.addUserScript(inject)
        }
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
        if WindowDebug.enabled {
            let winHandles = handlesBangs.filter { $0.hasPrefix("sd.window.") }.sorted()
            WindowDebug.log("stack \(manifest.id) handles=\(winHandles)")
        }
        // (Per-stack WindowsLifecycleObserver.subscribe() removed in the
        // Slice 4 rework. The poll is now always-on at startup as a
        // safety backstop alongside WindowsAXObserver; no per-stack gate
        // — gating both the source and the fan-out on the same manifest
        // field was a single point of failure. AX is primary, the poll
        // is the drift sensor.)
        startChannels(permissions: manifest.permissions)
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
                    log("unknown eventtap type \(et.event)")
                    continue
                }
                let cb = et.callback
                if et.consume == true {
                    let predicate = Bridge.buildPredicate(et.`if`)
                    let key = Bridge.eventTapKey(stackId: manifest.id, callback: cb, owner: self)
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
                    // Observe-side rect gate (same key shape as the consume
                    // path) lets framemaster-style hot corners stop polling
                    // sd.mouse at 30Hz: declare the tap with requireRects,
                    // push the hit zones via sd.events.setTapRects, and the
                    // callback only fires when the cursor lands inside one.
                    let key = Bridge.eventTapKey(stackId: manifest.id, callback: cb, owner: self)
                    if et.requireRects == true {
                        EventTapRegistry.shared.setConsumerRects(key: key, rects: [])
                    }
                    let observerKey: String? = (et.requireRects == true) ? key : nil
                    let emitLeave = (et.emitLeave == true) && (et.requireRects == true)
                    scope.adopt(EventTapRegistry.shared.register(
                        eventType: type, key: observerKey, emitLeave: emitLeave
                    ) { [weak self] event, phase in
                        self?.fireEventTap(callback: cb, type: type, event: event, phase: phase)
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
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for t in self.desktopIconHolds { t.cancel() }
            self.desktopIconHolds.removeAll()
        })
        // Release every handle a primitive minted and JS didn't release, so a
        // reload doesn't leak registrations: SIGTERM streamed subprocesses,
        // close SQLite connections, stop recognizers / captures / queries /
        // browsers / servers (answering in-flight HTTP requests 503 so their
        // NWConnection is freed), release wake-locks, and drop URL-scheme
        // subscribers, DN observers, Carbon hotkeys and status items.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            for h in self.procStreamHandles.drain() { h.cancel() }
            for h in self.sqliteHandles { SQLite.close(handle: h) }
            self.sqliteHandles.removeAll()
            self.speechListenHandles.cancelAll()
            self.windowStreamHandles.cancelAll()
            self.cameraStreamHandles.cancelAll()
            self.spotlightLiveHandles.cancelAll()
            self.bonjourPublishHandles.cancelAll()
            self.bonjourBrowseHandles.cancelAll()
            self.httpServerTokens.cancelAll()
            for complete in self.pendingHttpResponses.drain() {
                complete(HTTPResponse(status: 503, headers: [:], body: "stack unloaded"))
            }
            for id in self.caffeinateAssertions.drain() { Caffeinate.release(id: id) }
            self.urlHandlerTokens.cancelAll()
            self.broadcastTokens.cancelAll()
            self.hotkeyTokens.cancelAll()
            for h in self.statusItems.drain() { h.remove() }
        })
        // Overlays — cancel each region's cursor follow, then detach each
        // handle (stops its ticking and closes the overlay NSPanel) so a
        // hot-reload doesn't leak panels. NSPanel.close must run on main;
        // we sync-hop (matching the per-call overlay.detach path) so the panels are
        // actually torn down before the new stack instance has a chance
        // to attach its own — otherwise a hot-reload of overlay-border
        // produces two visible outlines until the OS gets around to
        // running the async block.
        scope.adopt(Token { [weak self] in
            guard let self = self else { return }
            self.regionFollowTokens.cancelAll()
            let handles = self.overlayHandles.drain()
            let regionHandles = self.regionOverlayHandles.drain()
            if Thread.isMainThread {
                for h in handles { h.detach() }
                for h in regionHandles { h.remove() }
            } else {
                DispatchQueue.main.sync {
                    for h in handles { h.detach() }
                    for h in regionHandles { h.remove() }
                }
            }
        })
    }

    func handles(bang: String) -> Bool { handlesBangs.contains(bang) }

    /// The stack's display changed geometry without a reload: replace the
    /// page's screen info (sd.screen.current / window.__sd_screen) and fire
    /// `sd:screen` so stacks that laid out from it can redo it.
    func updateScreen(_ screen: NSScreen, index: Int) {
        guard webView != nil else { return }
        let payload = Bridge.jsonify(Bridge.screenInfo(screen: screen, index: index))
        send("window.__sd_screen=\(payload);if(window.sd&&sd.screen)sd.screen.current=window.__sd_screen;window.dispatchEvent(new CustomEvent('sd:screen',{detail:window.__sd_screen}));")
    }

    /// Detail can hold any JSON-compatible Any (String, Int, Bool, Array, Dict).
    /// Useful for system-fired bangs (window lifecycle) carrying structured
    /// data — CLI-fired bangs still pass [String: String] which round-trips fine.
    func fireBang(name: String, detail: [String: Any]) {
        fireBang(name: name, json: Bridge.jsonify(detail))
    }

    /// Pre-serialized variant so a fan-out across stacks encodes once.
    func fireBang(name: String, json: String) {
        send(Bridge.bangScript(name: name, json: json))
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
            log("js[\(level)] \(msg)")
            return
        }
        guard message.name == "sd", let body = message.body as? [String: Any] else { return }
        let requestId = body["requestId"] as? Int ?? -1
        // An unanswered request leaves its JS Promise pending forever, so an
        // unknown type still resolves — with null, the runtime's failure value.
        let typeName = body["type"] as? String
        guard let type = typeName, let primitive = Bridge.dispatch[type] else {
            log("\(stackId): unknown primitive \(typeName ?? "<missing type>") — answered null")
            respond(requestId: requestId, value: nil)
            return
        }
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
                log("rpc \(stackId) → \(type)")
            }
        }
        if let perm = primitive.permission, !permissions.contains(perm) {
            // Single-line guidance: the manifest is right there in the stack
            // folder; this tells the author exactly what to add.
            log("\(type) denied — add \"\(perm)\" to permissions in stack.json")
            // Per-primitive denial value (false for void/Bool-returning, NSNull
            // for nullable readers) so a denied call returns the same shape a
            // granted one would.
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
    ///
    /// Widened from fileprivate to internal so primitive groups extracted into
    /// their own files (BridgeAudio.swift, BridgeFS.swift, BridgeSearch.swift)
    /// can still call `bridge.respond(...)` from inside their `.custom` /
    /// `.syncBridge` closures. The method is still module-internal — no public
    /// API surface change.
    func respond(requestId: Int, value: Any?) {
        guard webView != nil else { return }
        let json = value.map { Bridge.jsonify($0) } ?? "null"
        send(Bridge.responseScript(requestId: requestId, json: json))
    }

    /// Queue `script` for this stack's page. Every send — pushes, responses,
    /// bangs, callback fires — goes through the outbox, from any thread, so
    /// the page runs them in call order; whatever was sent during one
    /// run-loop pass is evaluated as one script when the pass ends.
    func send(_ script: String) {
        guard webView != nil, outbox.append(script) else { return }
        EvalOutbox.atTurnEnd { [weak self] in self?.flushOutbox() }
    }

    private func flushOutbox() {
        guard let script = outbox.take(), let webView = webView else { return }
        eval(script, in: webView)
    }

    /// Evaluate a script in this stack's WebView — inline when already on
    /// main with nothing queued, otherwise hopped to main in order.
    /// evaluateJavaScript is itself asynchronous (it posts to the WebContent
    /// process), so running it inline can't re-enter page JS.
    private func eval(_ script: String, in webView: WKWebView) {
        evalGateLock.lock()
        let inline = evalGate.shouldRunInline(isMain: Thread.isMainThread)
        evalGateLock.unlock()
        if inline {
            webView.sdEvaluate(script, completionHandler: nil)
            return
        }
        DispatchQueue.main.async { [weak self] in
            webView.sdEvaluate(script, completionHandler: nil)
            guard let self = self else { return }
            self.evalGateLock.lock()
            self.evalGate.drained()
            self.evalGateLock.unlock()
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

    /// Composed at load time from a handful of extracted group builders
    /// (`BridgeAudio.swift`, `BridgeFS.swift`, `BridgeSearch.swift`) plus
    /// every primitive that's still inline below. The group builders take
    /// no arguments and capture no Bridge state — each `.custom` /
    /// `.syncBridge` entry receives the calling Bridge through the
    /// dispatch shim, identical to the inline shape.
    ///
    /// Ordering note: dispatch is a `[String: Primitive]` Dictionary built
    /// from this list, so the array order doesn't affect runtime resolution.
    /// Group concatenation order is alphabetical by domain (audio → fs →
    /// search) just to keep the diff legible — there's no behavioral
    /// significance to it.
    private static let primitives: [Primitive] =
        Bridge.appsPrimitives()
        + Bridge.calendarPrimitives()
        + Bridge.nlpPrimitives()
        + Bridge.audioPrimitives()
        + Bridge.fsPrimitives()
        + Bridge.spotlightPrimitives()
        + Bridge.speechPrimitives()
        + Bridge.displayPrimitives()
        + Bridge.cameraPrimitives()
        + Bridge.bonjourPrimitives()
        + Bridge.procPrimitives()
        + Bridge.caffeinatePrimitives()
        + Bridge.stacksPrimitives()
        + Bridge.sqlitePrimitives()
        + Bridge.hotkeyPrimitives()
        + Bridge.broadcastsPrimitives()
        + Bridge.urlHandlerPrimitives()
        + Bridge.overlayPrimitives()
        + Bridge.httpServerPrimitives()
        + Bridge.storagePrimitives()
        + Bridge.menubarPrimitives()
        + Bridge.desktopPrimitives()
        + Bridge.axPrimitives()
        + Bridge.eventsPrimitives()
        + Bridge.windowsPrimitives()
        + Bridge.windowPrimitives()
        + Bridge.inlinePrimitives()

    /// Every permission string declared by any primitive — `.sync(...)`,
    /// `.custom(...)`, `.ax(...)`, or `.syncBridge(...)` registration in
    /// `primitives` (now composed across BridgeAudio/FS/Search + inline).
    /// `Tests/PermissionsRegistryTests.swift` asserts this is a subset of
    /// `Permissions.all` — adding a new primitive with a permission not in
    /// the canonical registry fails CI before the commit lands. Same-commit
    /// guard for the doctor-allowlist rule (see CLAUDE.md).
    static let primitivePermissions: Set<String> =
        Set(primitives.compactMap { $0.permission })

    /// What a stack can observe of each primitive without calling it: the
    /// wire type, its permission gate, and the JSON a denied call resolves
    /// to. Sorted by type. `Tests/PublicSurfaceTests.swift` snapshots it.
    static var primitiveContract: [(type: String, permission: String?, deny: String)] {
        primitives.map { ($0.type, $0.permission, jsonify($0.denyValue)) }
            .sorted { $0.type < $1.type }
    }

    /// Every primitive that wasn't pulled into a `Bridge<Group>.swift`
    /// file yet. Lives as a method (not a let) so the source order can
    /// stay roughly historical — moving them out one group at a time
    /// won't reshuffle the rest of the table.
    private static func inlinePrimitives() -> [Primitive] { [
        // Bootstrap
        .custom("ready") { bridge, _, _ in bridge.replayState() },

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

        // Media
        .sync("media.command", permission: "media", denyValue: false) { body in
            Media.command(body["name"] as? String ?? "")
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

        // Haptic: trackpad Taptic Engine click. Fire-and-forget; false for
        // an unknown pattern name.
        .sync("haptic.perform", permission: "haptic", denyValue: false) { body in
            Haptic.perform(body["pattern"] as? String)
        },
        .sync("haptic.actuate", permission: "haptic", denyValue: false) { body in
            guard let id = Haptic.actuationID(from: body["id"]) else { return false }
            let device = (body["device"] as? NSNumber)?.uint64Value
            return Haptic.actuate(id, device: device)
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

        // Curated AX surface for the system-wide focused text element.
        // Collapses the five-call sd.ax.{focused,attribute,parameterizedAttribute,
        // release} dance into one call for per-tick text transformations.
        // `.ax` (main-hop) because AX traffic
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

        // SF Symbol → template PNG data-URL for WKWebView consumers (the bar
        // masks it with currentColor). Returns { dataURL, width, height } or nil.
        .sync("symbol", permission: "symbol") { body in
            Symbols.render(name:      body["name"]   as? String ?? "",
                           pointSize: body["size"]   as? Int    ?? 15,
                           weight:    body["weight"] as? String ?? "regular",
                           scale:     body["scale"]  as? String ?? "medium")
        },

        // Spaces — returns array; denies to an empty array.
        .sync("spaces.windowSpaces", permission: "spaces", denyValue: [NSNumber]()) { body in
            Spaces.windowSpaces(windowID: UInt32((body["id"] as? Int) ?? 0)).map { NSNumber(value: $0) }
        },
        .sync("spaces.minimizedWindows", permission: "spaces", denyValue: [NSNumber]()) { body in
            let id = UInt64((body["spaceID"] as? Int) ?? 0)
            return Spaces.minimizedWindows(spaceID: id).map { NSNumber(value: $0) }
        },
        // Write side — verified move; { ok, spaces } either way so callers
        // can update their per-window space caches without polling.
        .sync("spaces.moveWindow", permission: "spaces",
              denyValue: ["ok": false, "spaces": [NSNumber]()] as [String: Any]) { body in
            Spaces.moveWindow(
                windowID: UInt32((body["id"] as? Int) ?? 0),
                toSpace: UInt64((body["spaceID"] as? Int) ?? 0))
        },

        // Native popup menu — async (resolves on user pick / cancel).
        .custom("menu.popup", permission: "menu") { bridge, body, requestId in
            let items = body["items"] as? [[String: Any]] ?? []
            PopupMenu.present(items: items) { [weak bridge] picked in
                bridge?.respond(requestId: requestId, value: picked as Any? ?? NSNull())
            }
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
            // touchdevice is event-driven and its frames carry began/ended
            // edges a time gate would drop, so the interval is accepted
            // and ignored there.
            if name == "touchdevice" { return true }
            if let interval = body["interval"] as? Double, interval > 0 {
                b.channelIntervals[name] = interval
            } else {
                b.channelIntervals.removeValue(forKey: name)
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
        },

        // Runtime handles-registration. Lets `sd.bang.declare(name).on(fn)` in
        // JS opt this stack into the dispatch list without requiring the same
        // name in the manifest `handles` array. The api.js bang router fires
        // this on first declaration per slug. Idempotent — the set absorbs
        // repeat calls. No permission gate (subscribing to a bang isn't a
        // sensitive op — anyone can call .declare() on any name).
        .syncBridge("bang.handle", permission: nil, denyValue: false) { bridge, body in
            guard let name = body["name"] as? String, !name.isEmpty else { return false }
            bridge.handlesBangs.insert(name)
            return true
        }
    ] }

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
        send(Bridge.globalScript(handler: handler, args: args))
    }

    /// Widened from private to internal so fs.watch.start's callback (now in
    /// BridgeFS.swift) can hand events back through this dispatch path.
    func dispatchFsEvents(watchId: Int, events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let payload = events.map { ev -> [String: Any] in
            ["path": ev.path, "kind": FSWatch.kindFor(flags: ev.flags)]
        }
        fireGlobal(handler: "__sd_fs_event", args: ["\(watchId)", Bridge.jsonify(payload)])
    }

    /// Pump a menubar-item click / pick / etc. back to JS. The JS-side proxy
    /// in api.js (sd.menubar.addItem) routes this to the stack's callbacks.
    /// Widened from fileprivate to internal so BridgeMenubar.swift's
    /// menubar.addItem closure can pump click / pick events back to JS.
    /// Hand a region overlay page's `window.stack.post(data)` to the stack's
    /// handle.onMessage (routed by region id in Runtime/src/19-ipc.js).
    func dispatchOverlayMessage(regionId: Int, data: Any) {
        fireGlobal(handler: "__sd_overlay_message", args: ["\(regionId)", Bridge.jsonify(data)])
    }

    func dispatchMenubarEvent(itemId: Int, type: String, payload: Any?) {
        let payloadJson = payload.map { Bridge.jsonify($0) } ?? "null"
        fireGlobal(handler: "__sd_menubar_event",
                   args: ["\(itemId)", Bridge.jsString(type), payloadJson])
    }

    // replayState iterates Channels.all (single source of truth shared with
    // the JS-side __sdSignalPaths). For each replayable channel where the
    // stack has the gating permission AND lastState[channel.name] exists,
    // push the cached JSON so a newly-ready stack starts with current state.
    //
    // Iteration order matters — it's the firing order on stack ready. The
    // registry preserves the historical replayTable order.
    private func replayState() {
        for ch in Channels.all {
            guard ch.replayable,
                  permissions.contains(ch.permission),
                  let json = lastState[ch.name] else { continue }
            push(channel: ch.name, json: json)
        }
    }

    /// Refire `pushFn` (frontApp + focusedWindow + windowsAll + the
    /// matching deltas). AppDelegate calls this on every window
    /// create / destroy / title-change so stacks see `sd.windows.all`
    /// reflect the new set within one runloop hop instead of waiting for
    /// the next focus change. No-op when this Bridge didn't subscribe to
    /// the workspace pump (no `windows` / `app` permission).
    func pumpWindowsList() {
        windowsListPump?()
    }

    private func fireHotkey(callback: String) {
        // Strip embedded quotes defensively — the callback comes from a stack
        // manifest, and `onHotkey_<callback>` is interpolated into the lookup
        // name. fireGlobal escapes the resulting key for us via jsString.
        let safe = callback.replacingOccurrences(of: "\"", with: "")
        fireGlobal(handler: "onHotkey_\(safe)")
    }

    private func fireEventTap(callback: String, type: CGEventType, event: CGEvent, phase: String? = nil) {
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
        case .scrollWheel:
            for (k, v) in ScrollWheel.payload(ScrollWheel.read(event)) { payload[k] = v }
        default: break
        }
        if type.rawValue == Gesture.cgEventType.rawValue,
           let g = Gesture.describe(cgEvent: event) {
            for (k, v) in g { payload[k] = v }
        }
        // `phase` is only present when the manifest opted in via
        // `emitLeave: true`. The observer-tap dispatch path supplies
        // "enter" / "move" / "leave" for transition-aware handlers; every
        // other observer-tap call site (and every consume-side fire) leaves
        // it nil so the payload stays byte-identical to the pre-leave
        // shape that existing stacks read.
        if let phase = phase { payload["phase"] = phase }

        fireGlobal(handler: "onTap_\(callback)", args: [Bridge.jsonify(payload)])
    }

    /// Widened from private to internal so primitive groups extracted into
    /// their own files can push per-handle channels (spotlight:subscribe:<id>,
    /// speech:listen:<id>, …) without going through a re-export shim.
    func push(channel: String, json: String) {
        guard webView != nil else { return }
        // Trace every channel push when STACKD_RPC_DEBUG=1. Same throttle
        // shape as the RPC tracer above. Off by default — high-rate
        // channels (sd.mouse, sd.windows.all) would otherwise spam stderr.
        if Bridge.rpcTraceEnabled {
            let now = Date().timeIntervalSince1970
            let lastLogged = Bridge.lastPushLogged[channel] ?? 0
            if now - lastLogged >= Bridge.pushLogThrottleSec {
                Bridge.lastPushLogged[channel] = now
                let preview = json.count > 120 ? String(json.prefix(117)) + "..." : json
                log("push \(channel) (\(json.count)B) \(preview)")
            }
        }
        send(Bridge.pushScript(channel: channel, json: json))
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

/// Decides whether a script may be evaluated inline or must hop to main.
/// Inline only on main with nothing queued: once any script is queued,
/// later ones queue behind it so a stack sees them in call order.
struct EvalOrderGate {
    private var pending = 0

    /// Counts the script as queued when it returns false.
    mutating func shouldRunInline(isMain: Bool) -> Bool {
        if isMain && pending == 0 { return true }
        pending += 1
        return false
    }

    /// A queued script ran.
    mutating func drained() { pending = max(0, pending - 1) }
}
