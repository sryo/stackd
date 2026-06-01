import Foundation

// One-shot Spotlight queries via NSMetadataQuery, plus a long-lived
// "subscribe" mode that keeps the query alive and re-pushes the full
// current result-set every time the Spotlight index notifies a change.
// Public framework, no TCC prompts — Spotlight's index is readable to
// the user's processes by default.
//
// One-shot (Spotlight.find): gathers all matches once
// (NSMetadataQueryDidFinishGathering on the main runloop), snapshots the
// results and stops the query.
//
// Live (Spotlight.LiveQuery): keeps the query alive after the initial
// gathering finishes — re-enables updates and listens for both
// NSMetadataQueryDidFinishGathering AND NSMetadataQueryDidUpdate so any
// index churn (new screenshot, file moved into scope, mtime bumped) fires
// a fresh snapshot push to the subscriber. The callback always receives
// the FULL current result-set, same shape as the one-shot — diffing is
// the caller's job (most stacks just re-render).
//
// Consumers — "files modified in the last hour" widget, "find every PDF
// containing this string" launcher, "newest screenshot" thumbnail strip,
// "live Downloads since yesterday" auto-updating list. Pairs with sd.fs
// for follow-up reads on the matched paths.

enum Spotlight {
    /// Run a Spotlight query and return matching items.
    ///
    /// - `predicate`: raw NSPredicate format string (e.g.
    ///   `kMDItemFSName LIKE[cd] '*.pdf'`, or
    ///   `kMDItemFSContentChangeDate > $time.today(-1)`). Required; nil/empty
    ///   means "match nothing" and the callback receives an empty array.
    /// - `scopes`: optional array of absolute paths to limit the search to.
    ///   Defaults to `NSMetadataQueryLocalComputerScope` (everything indexed
    ///   on this Mac). A custom scope like `["/Users/me/Screenshots"]` is the
    ///   right call for widgets that always look in one directory.
    /// - `attributes`: kMDItem* keys to copy into the result dicts. nil falls
    ///   back to a useful default set (name, path, type, change date, size).
    /// - `limit`: cap the result count. nil = unbounded.
    ///
    /// Returns items as `[[String: Any]]` with attribute keys preserved
    /// verbatim (e.g. `"kMDItemFSName"`). Dates are converted to UNIX
    /// timestamps (Double) and URLs to path strings so JSON serialization
    /// works directly. Returns nil only if the predicate fails to parse.
    static func find(predicate: String?,
                     scopes: [String]?,
                     attributes: [String]?,
                     limit: Int?,
                     completion: @escaping ([[String: Any]]?) -> Void) {
        guard let predicateStr = predicate, !predicateStr.isEmpty else {
            completion([]); return
        }

        // NSPredicate.init(format:) raises NSInvalidArgumentException on a
        // malformed format string. We can't catch Objective-C exceptions
        // from Swift, so the daemon would crash on bad input. Mitigation:
        // require the JS caller to provide valid predicates; document this
        // in the api.js comment. The cost of a richer guard (objc shim)
        // isn't worth it for a one-shot query.
        let predicate = NSPredicate(format: predicateStr)
        let query = NSMetadataQuery()
        query.predicate = predicate

        if let scopes = scopes, !scopes.isEmpty {
            query.searchScopes = scopes
        } else {
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
        }

        let attrs = normalizedAttributes(attributes)

        // Capture the observer in a Box so the closure can self-remove
        // once gathering is done — NSNotificationCenter doesn't expose a
        // one-shot helper for object-scoped observation.
        final class ObserverBox { var token: NSObjectProtocol? }
        let box = ObserverBox()
        box.token = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query, queue: .main
        ) { _ in
            query.disableUpdates()
            let results = snapshot(query: query, attributes: attrs, limit: limit)
            query.stop()
            if let token = box.token {
                NotificationCenter.default.removeObserver(token)
            }
            completion(results)
        }

        // NSMetadataQuery must be started on the main runloop — its delegate
        // dispatch (gathering progress, finish) runs there too.
        DispatchQueue.main.async { query.start() }
    }

    /// Long-lived Spotlight query — fires `onUpdate` with the FULL current
    /// result-set on every index change. First emit happens after the
    /// initial gathering finishes (NSMetadataQueryDidFinishGathering),
    /// subsequent emits ride NSMetadataQueryDidUpdate.
    ///
    /// Construction returns immediately; the first push lands asynchronously
    /// once Spotlight finishes the initial gather (usually < 1s for narrow
    /// predicates, longer for whole-disk scans). If the predicate is empty
    /// or malformed-by-format, the live query never emits — caller-side
    /// validation is the contract (see `find()` for the same note).
    ///
    /// Lifetime: caller MUST hold a strong reference to the LiveQuery; on
    /// stop() the underlying NSMetadataQuery + notification observers are
    /// torn down. Stack reload should drop the reference (Bridge owns the
    /// drain via spotlightLiveHandles).
    final class LiveQuery {
        private var query: NSMetadataQuery?
        private var finishToken: NSObjectProtocol?
        private var updateToken:  NSObjectProtocol?
        private let attributes: [String]
        private let limit: Int?
        private let onUpdate: ([[String: Any]]) -> Void

        init?(predicate: String?,
              scopes: [String]?,
              attributes: [String]?,
              limit: Int?,
              onUpdate: @escaping ([[String: Any]]) -> Void) {
            guard let predicateStr = predicate, !predicateStr.isEmpty else {
                return nil
            }

            // Same NSPredicate caveat as Spotlight.find: a malformed format
            // string raises NSInvalidArgumentException and crashes the
            // daemon. Caller validates.
            let predicate = NSPredicate(format: predicateStr)
            let query = NSMetadataQuery()
            query.predicate = predicate

            if let scopes = scopes, !scopes.isEmpty {
                query.searchScopes = scopes
            } else {
                query.searchScopes = [NSMetadataQueryLocalComputerScope]
            }

            self.query = query
            self.attributes = normalizedAttributes(attributes)
            self.limit = limit
            self.onUpdate = onUpdate

            // Subscribe to BOTH the initial-gather finish and the live
            // update notifications. The finish handler does NOT stop the
            // query — instead it re-enables updates so the index can keep
            // delivering NSMetadataQueryDidUpdate notifications. Both
            // handlers funnel through pushSnapshot() so subscribers see a
            // consistent shape on first push and every push after.
            finishToken = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query, queue: .main
            ) { [weak self] _ in
                guard let self = self, let q = self.query else { return }
                // disableUpdates() while we snapshot, then enableUpdates()
                // so we receive subsequent NSMetadataQueryDidUpdate pushes.
                // Apple's docs require the disable/enable bracket around
                // any query-result iteration in live mode.
                q.disableUpdates()
                self.pushSnapshot()
                q.enableUpdates()
            }
            updateToken = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query, queue: .main
            ) { [weak self] _ in
                guard let self = self, let q = self.query else { return }
                q.disableUpdates()
                self.pushSnapshot()
                q.enableUpdates()
            }

            // NSMetadataQuery must start on the main runloop — its
            // notification dispatch runs there too.
            DispatchQueue.main.async { query.start() }
        }

        /// Tear down the underlying query + observers. Idempotent.
        func stop() {
            if let token = finishToken {
                NotificationCenter.default.removeObserver(token)
                finishToken = nil
            }
            if let token = updateToken {
                NotificationCenter.default.removeObserver(token)
                updateToken = nil
            }
            if let q = query {
                q.disableUpdates()
                q.stop()
                query = nil
            }
        }

        private func pushSnapshot() {
            guard let q = query else { return }
            onUpdate(Spotlight.snapshot(query: q, attributes: attributes, limit: limit))
        }
    }

    // ── pure helpers (testable) ──────────────────────────────────────────

    /// Baseline attribute set returned when the caller doesn't pass an
    /// explicit `attributes` list. Pinned by SpotlightLiveTests so drift
    /// in this list shows up as a test failure rather than silently
    /// breaking every stack relying on the default fields.
    static let defaultAttributes: [String] = [
        "kMDItemFSName",
        "kMDItemPath",
        "kMDItemContentType",
        "kMDItemFSContentChangeDate",
        "kMDItemFSCreationDate",
        "kMDItemFSSize"
    ]

    /// "Caller-passed attributes vs fallback" decision shared by find()
    /// and LiveQuery. nil / empty → defaultAttributes; non-empty list
    /// passes through verbatim. Extracted so both paths can't drift.
    static func normalizedAttributes(_ caller: [String]?) -> [String] {
        guard let caller = caller, !caller.isEmpty else { return defaultAttributes }
        return caller
    }

    /// NSDate → epoch seconds (Double), URL → path String. Everything else
    /// passes through — kMDItem* attribute values are NSNumber / NSString /
    /// arrays of those, all JSON-able by default.
    static func jsonableValue(_ v: Any) -> Any {
        if let d = v as? Date { return d.timeIntervalSince1970 }
        if let u = v as? URL  { return u.path }
        return v
    }

    // ── snapshot ─────────────────────────────────────────────────────────

    /// Materialize the current NSMetadataQuery result-set into a JSON-able
    /// `[[String: Any]]` shape. Caller is responsible for the disable /
    /// enable updates bracket — both find() and LiveQuery handle that
    /// before invoking this. Not pure (touches query.resultCount /
    /// result(at:)), so it doesn't live in the testable surface above.
    private static func snapshot(query: NSMetadataQuery,
                                 attributes: [String],
                                 limit: Int?) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }
            var entry: [String: Any] = [:]
            for attr in attributes {
                if let v = item.value(forAttribute: attr) {
                    entry[attr] = jsonableValue(v)
                }
            }
            results.append(entry)
            if let lim = limit, results.count >= lim { break }
        }
        return results
    }
}
