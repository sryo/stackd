import Foundation

/// Pure delta computation — extracted from Bridge.swift in the A8 breakup
/// round. `computeDelta` is the generic added/removed/changed walk;
/// `windowsDelta` / `displaysDelta` / `menubarDelta` are the per-channel
/// adapters that plug in identity + equality. All four stay `static` on
/// `Bridge` so call sites (`Bridge.computeDelta(...)`) and the
/// ComputeDelta / WindowsChanged / DisplaysChanged / MenubarChanged test
/// suites keep working unchanged.
extension Bridge {
    /// Generic added/removed/changed walk shared by `windowsDelta`,
    /// `displaysDelta`, `menubarDelta`. Each caller plugs in its own
    /// identity (how to key a row) and equality (which fields gate
    /// `changed`); the loop below is identical. Returns the new
    /// key-indexed cache so callers don't re-walk the snapshot.
    ///
    /// Rows whose `identity` returns nil are dropped (e.g. missing `id` /
    /// `displayID`).
    static func computeDelta<K: Hashable>(
        snapshot: [[String: Any]],
        previous: [K: [String: Any]],
        identity: (_ item: [String: Any]) -> K?,
        equal: (_ prev: [String: Any], _ now: [String: Any]) -> Bool
    ) -> (added: [[String: Any]], removed: [[String: Any]], changed: [[String: Any]], nowByKey: [K: [String: Any]]) {
        var nowByKey: [K: [String: Any]] = [:]
        for item in snapshot {
            if let k = identity(item) { nowByKey[k] = item }
        }
        var added:   [[String: Any]] = []
        var removed: [[String: Any]] = []
        var changed: [[String: Any]] = []
        for (k, item) in nowByKey {
            if let prev = previous[k] {
                if !equal(prev, item) { changed.append(item) }
            } else {
                added.append(item)
            }
        }
        for (k, item) in previous where nowByKey[k] == nil {
            removed.append(item)
        }
        return (added, removed, changed, nowByKey)
    }

    /// Pure delta computation between two menubar snapshots. Identity is
    /// `"<owner>|<title>"` — menubar items have no stable id, so we key
    /// by the closest persistent thing (owner app + item title). A rename
    /// in place surfaces as a paired removed+added.
    static func menubarDelta(snapshot: [[String: Any]], previous: [String: [String: Any]])
        -> (added: [[String: Any]], removed: [[String: Any]], changed: [[String: Any]], nowByKey: [String: [String: Any]])
    {
        return computeDelta(
            snapshot: snapshot,
            previous: previous,
            identity: { item in
                let owner = (item["owner"] as? String) ?? ""
                let title = (item["title"] as? String) ?? ""
                return owner + "|" + title
            },
            equal: { prev, item in
                // x + width + hidden are the only transition-y fields.
                // owner / title are part of the key; they can't differ
                // here by construction.
                return (prev["x"]      as? Double) == (item["x"]      as? Double) &&
                       (prev["width"]  as? Double) == (item["width"]  as? Double) &&
                       (prev["hidden"] as? Bool)   == (item["hidden"] as? Bool)
            }
        )
    }

    /// Pure delta computation between two display snapshots. Identity is
    /// displayID (CGDirectDisplayID); the "changed" detector compares
    /// frame.{x,y,w,h} and brightness — the two fields that change at
    /// macro frequency (arrangement / resolution / slider). Name, scale,
    /// uuid, builtin are treated as immutable; if they ever do change
    /// they'll surface as a paired removed+added.
    static func displaysDelta(snapshot: [[String: Any]], previous: [Int: [String: Any]])
        -> (added: [[String: Any]], removed: [[String: Any]], changed: [[String: Any]], nowByID: [Int: [String: Any]])
    {
        let d = computeDelta(
            snapshot: snapshot,
            previous: previous,
            identity: { $0["displayID"] as? Int },
            equal: { prev, now in
                let b1 = (prev["brightness"] as? Float)
                let b2 = (now["brightness"]  as? Float)
                let f1 = (prev["frame"] as? [String: Any]) ?? [:]
                let f2 = (now["frame"]  as? [String: Any]) ?? [:]
                return b1 == b2 &&
                    (f1["x"] as? Int) == (f2["x"] as? Int) &&
                    (f1["y"] as? Int) == (f2["y"] as? Int) &&
                    (f1["w"] as? Int) == (f2["w"] as? Int) &&
                    (f1["h"] as? Int) == (f2["h"] as? Int)
            }
        )
        return (d.added, d.removed, d.changed, d.nowByKey)
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
        let d = computeDelta(
            snapshot: snapshot,
            previous: previous,
            identity: { $0["id"] as? Int },
            equal: { prev, now in
                let t1 = (prev["title"] as? String) ?? ""
                let t2 = (now["title"]  as? String) ?? ""
                let f1 = (prev["frame"] as? [String: Any]) ?? [:]
                let f2 = (now["frame"]  as? [String: Any]) ?? [:]
                return t1 == t2 &&
                    (f1["x"] as? Int) == (f2["x"] as? Int) &&
                    (f1["y"] as? Int) == (f2["y"] as? Int) &&
                    (f1["w"] as? Int) == (f2["w"] as? Int) &&
                    (f1["h"] as? Int) == (f2["h"] as? Int)
            }
        )
        return (d.added, d.removed, d.changed, d.nowByKey)
    }

    /// Pure delta computation between two running-apps snapshots. Identity is
    /// bundleId; the "changed" detector compares active / hidden / name — the
    /// only fields NSRunningApplication flips during a process's lifetime, so a
    /// jsonify round-trip can't false-fire on Swift dict key-order noise.
    /// WebKit GPU + Networking helpers share a bundleId across every WKWebView
    /// (one process per stack), so keying is last-wins — the delta cares about
    /// transitions, not which specific PID landed.
    static func appsDelta(snapshot: [[String: Any]], previous: [String: [String: Any]])
        -> (added: [[String: Any]], removed: [[String: Any]], changed: [[String: Any]], nowByBundle: [String: [String: Any]])
    {
        let d = computeDelta(
            snapshot: snapshot,
            previous: previous,
            identity: { $0["bundleId"] as? String },
            equal: { prev, now in
                ((prev["active"] as? Bool)   ?? false) == ((now["active"] as? Bool)   ?? false) &&
                ((prev["hidden"] as? Bool)   ?? false) == ((now["hidden"] as? Bool)   ?? false) &&
                ((prev["name"]   as? String) ?? "")    == ((now["name"]   as? String) ?? "")
            }
        )
        return (d.added, d.removed, d.changed, d.nowByKey)
    }
}
