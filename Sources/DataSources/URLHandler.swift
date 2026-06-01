import AppKit

// Generic JS-side handler for custom-URL-scheme events. When another app
// opens a `myscheme://foo?bar=baz` URL and macOS routes it to stackd, the
// `NSAppleEventManager` `kAEGetURL` callback installed here parses the URL
// and fans out to every stack that registered a handler for that scheme.
//
// Backed by NSAppleEventManager (the macOS mechanism for receiving GURL
// Apple Events when a foreign app opens a URL). The daemon already has an
// NSApplication lifecycle (LSUIElement app), so the global handler is
// installable once at first subscribe and stays for the daemon's lifetime.
//
// Critical: for macOS to ROUTE `myscheme://...` to stackd at all, the
// daemon's Info.plist needs a CFBundleURLTypes entry naming the scheme.
// The daemon today is built as a plain `.build/stackd` binary, NOT an
// `.app` bundle — so during development, no `CFBundleURLTypes` is declared
// and URL events for custom schemes won't actually arrive. The API surface
// exists for when stackd ships as an `.app` with pre-declared schemes;
// the Swift code installs the AppleEventManager handler unconditionally so
// the wiring is ready. If URLs don't arrive, that's an Info.plist config
// issue, not a code bug.
//
// Pattern mirrors Broadcasts.swift: per-Bridge handle table in Bridge.swift,
// install-once observer here, observe(scheme: callback:) → Token. The
// SchemeRouter manages a process-global scheme → callbacks fan-out so
// multiple stacks can register handlers for the same scheme without
// fighting over the single NSAppleEventManager slot.
enum URLHandler {
    /// Process-global router. Each subscriber lands in a per-scheme bucket;
    /// the GURL handler looks up the bucket and fans out.
    static let router = SchemeRouter.shared

    /// Subscribe a callback to a scheme. install() is idempotent — the
    /// NSAppleEventManager slot is taken on first call and reused after.
    /// Returns a Token that removes this subscriber on cancel.
    static func observe(scheme: String,
                        callback: @escaping ([String: Any]) -> Void) -> Token {
        router.installIfNeeded()
        let key = scheme.lowercased()
        let id = router.add(scheme: key, callback: callback)
        return Token { router.remove(scheme: key, id: id) }
    }
}

/// Per-scheme subscriber registry + the one and only NSAppleEventManager
/// handler instance. NSObject so AppleEventManager can target the selector.
final class SchemeRouter: NSObject {
    static let shared = SchemeRouter()

    private var installed = false
    private var nextId: Int = 1
    /// scheme (lowercased) → [subscriberId: callback]
    private var subscribers: [String: [Int: ([String: Any]) -> Void]] = [:]
    private let lock = NSLock()

    func installIfNeeded() {
        lock.lock()
        let alreadyInstalled = installed
        installed = true
        lock.unlock()
        if alreadyInstalled { return }
        // setEventHandler must run on the main thread (it touches the
        // NSAppleEventManager singleton + AppKit state). install() is
        // typically called from a Bridge message dispatch which is already
        // on main, but hop defensively.
        if Thread.isMainThread {
            registerEventHandler()
        } else {
            DispatchQueue.main.sync { self.registerEventHandler() }
        }
    }

    private func registerEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func add(scheme: String, callback: @escaping ([String: Any]) -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        var bucket = subscribers[scheme] ?? [:]
        bucket[id] = callback
        subscribers[scheme] = bucket
        return id
    }

    func remove(scheme: String, id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard var bucket = subscribers[scheme] else { return }
        bucket.removeValue(forKey: id)
        if bucket.isEmpty {
            subscribers.removeValue(forKey: scheme)
        } else {
            subscribers[scheme] = bucket
        }
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor,
                              replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event
                .paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .stringValue,
              let comps = URLComponents(string: urlString) else { return }
        let scheme = (comps.scheme ?? "").lowercased()
        guard !scheme.isEmpty else { return }

        // Parse query items into a flat [String: String]. Multi-value keys
        // collapse to last-write-wins — same shape Express / sd.httpserver
        // exposes; stacks that need full multi-value can re-parse the raw url.
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        let payload: [String: Any] = [
            "url":      urlString,
            "scheme":   scheme,
            "host":     comps.host ?? "",
            "path":     comps.path,
            "query":    query,
            "fragment": comps.fragment ?? ""
        ]

        lock.lock()
        let callbacks = Array((subscribers[scheme] ?? [:]).values)
        lock.unlock()
        guard !callbacks.isEmpty else { return }
        DispatchQueue.main.async {
            for cb in callbacks { cb(payload) }
        }
    }
}
