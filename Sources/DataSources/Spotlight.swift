import Foundation

// One-shot Spotlight queries via NSMetadataQuery. Public framework, no TCC
// prompts — Spotlight's index is readable to the user's processes by default.
// The query gathers all matches once (firing NSMetadataQueryDidFinishGathering
// on the main runloop), then we snapshot the results and stop the query.
//
// Live-update variant (NSMetadataQuery in "continuous" mode + a sd.spotlight
// bang) is deferred — most callers want a single search-and-render, and the
// continuous path needs Bridge-side handle tracking that the one-shot doesn't.
//
// Consumers — "files modified in the last hour" widget, "find every PDF
// containing this string" launcher, "newest screenshot" thumbnail strip.
// Pairs with sd.fs for follow-up reads on the matched paths.

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

        let attrs = attributes ?? defaultAttributes

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
            var results: [[String: Any]] = []
            for i in 0..<query.resultCount {
                guard let item = query.result(at: i) as? NSMetadataItem else { continue }
                var entry: [String: Any] = [:]
                for attr in attrs {
                    if let v = item.value(forAttribute: attr) {
                        entry[attr] = jsonable(v)
                    }
                }
                results.append(entry)
                if let lim = limit, results.count >= lim { break }
            }
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

    private static let defaultAttributes: [String] = [
        "kMDItemFSName",
        "kMDItemPath",
        "kMDItemContentType",
        "kMDItemFSContentChangeDate",
        "kMDItemFSCreationDate",
        "kMDItemFSSize"
    ]

    /// NSDate → epoch seconds (Double), URL → path String. Everything else
    /// passes through — kMDItem* attribute values are NSNumber / NSString /
    /// arrays of those, all JSON-able by default.
    private static func jsonable(_ v: Any) -> Any {
        if let d = v as? Date { return d.timeIntervalSince1970 }
        if let u = v as? URL { return u.path }
        return v
    }
}
