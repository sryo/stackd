import Foundation
import CoreGraphics

/// AppKit's native window tabs (Finder, Terminal, TextEdit, Preview, Xcode)
/// give each tab its own window id. Only the selected tab is on screen and
/// listed by Accessibility; the others stay at the same frame, hidden. They
/// are not windows anyone sees or tiles, so the window list leaves them out.
///
/// Selecting another tab swaps which id is visible at that frame, which looks
/// like one window replaced by another at the same place: the pairing stacks
/// already do for apps that recreate a window on a tab change.
enum WindowTabs {
    /// How far apart two windows' sizes may be and still be one tab group.
    private static let sizeTolerance = 2

    /// The ids in `rows` (Windows.all() rows) that are hidden tabs: not on
    /// screen, not minimized, absent from the app's current Accessibility
    /// window list, and the size of a visible, readable window of the same
    /// app, on the same Space or on none. The addressability verdict in the row is not
    /// used for a hidden window: the cache keeps a tab's earlier "readable"
    /// answer after another tab is selected.
    /// `spacesOf` and `axWindowIDs` (nil when the app cannot be read) are
    /// asked only for windows that pass the cheaper checks.
    static func siblingIDs(in rows: [[String: Any]],
                           spacesOf: (Int) -> Set<UInt64>,
                           axWindowIDs: (Int) -> Set<Int>?) -> Set<Int> {
        var anchorsByPid: [Int: [(id: Int, w: Int, h: Int)]] = [:]
        for r in rows where (r["onscreen"] as? Bool) == true && (r["addressable"] as? Bool) == true {
            guard let id = r["id"] as? Int, let pid = r["pid"] as? Int, let size = size(of: r) else { continue }
            anchorsByPid[pid, default: []].append((id, size.w, size.h))
        }
        guard !anchorsByPid.isEmpty else { return [] }

        var siblings = Set<Int>()
        var listed: [Int: Set<Int>?] = [:]
        for r in rows {
            guard (r["onscreen"] as? Bool) == false,
                  (r["isMinimized"] as? Bool) != true,
                  let id = r["id"] as? Int, let pid = r["pid"] as? Int,
                  let size = size(of: r),
                  let anchors = anchorsByPid[pid] else { continue }
            let matching = anchors.filter {
                abs($0.w - size.w) <= sizeTolerance && abs($0.h - size.h) <= sizeTolerance
            }
            guard !matching.isEmpty else { continue }
            // A hidden tab is ordered out, which files it under no Space; a
            // window on another Space is ordered in there, under that Space.
            let mine = spacesOf(id)
            guard mine.isEmpty
                    || matching.contains(where: { !spacesOf($0.id).isDisjoint(with: mine) }) else { continue }
            if listed[pid] == nil { listed[pid] = .some(axWindowIDs(pid)) }
            guard let inAX = listed[pid] ?? nil, !inAX.contains(id) else { continue }
            siblings.insert(id)
        }
        return siblings
    }

    /// `rows` without the hidden tabs in `siblings`. A visible tab whose own
    /// traits (resizable, fullscreen button) have not been read yet takes
    /// them from a hidden tab of the same app and size: the tabs are one
    /// window, and a tab with no traits is not tiled until they arrive, so
    /// the swap would leave a gap in the layout for as long as that read takes.
    static func inheritTraits(rows: [[String: Any]], siblings: Set<Int>) -> [[String: Any]] {
        guard !siblings.isEmpty else { return rows }
        let hidden = rows.filter { siblings.contains(($0["id"] as? Int) ?? -1) && $0["isResizable"] != nil }
        return rows.compactMap { r -> [String: Any]? in
            guard let id = r["id"] as? Int else { return r }
            if siblings.contains(id) { return nil }
            guard r["isResizable"] == nil, let pid = r["pid"] as? Int, let sz = size(of: r),
                  let donor = hidden.first(where: { h in
                      (h["pid"] as? Int) == pid
                          && size(of: h).map({ abs($0.w - sz.w) <= sizeTolerance && abs($0.h - sz.h) <= sizeTolerance }) == true
                  }) else { return r }
            var out = r
            for key in ["isResizable", "canFullscreen"] where donor[key] != nil { out[key] = donor[key] }
            return out
        }
    }

    /// Windows that share a size with another window of their app, with the
    /// fields the tab decision reads (for STACKD_WIN_DEBUG).
    static func debugSummary(_ rows: [[String: Any]], siblings: Set<Int>) -> String {
        var parts: [String] = []
        for r in rows {
            guard let id = r["id"] as? Int, let pid = r["pid"] as? Int, let sz = size(of: r),
                  rows.contains(where: { o in
                      (o["id"] as? Int) != id && (o["pid"] as? Int) == pid
                          && size(of: o).map({ abs($0.w - sz.w) <= sizeTolerance && abs($0.h - sz.h) <= sizeTolerance }) == true
                  }) else { continue }
            parts.append("\(id)[pid=\(pid) on=\(r["onscreen"] ?? "?") addr=\(r["addressable"] ?? "?") min=\(r["isMinimized"] ?? "?") \(siblings.contains(id) ? "TAB" : "kept")]")
        }
        return parts.isEmpty ? "-" : parts.joined(separator: " ")
    }

    /// Each app's listed window ids with on-screen and readable flags, for
    /// STACKD_WIN_DEBUG, logged only when it differs from the last call.
    private static var lastList = ""
    static func debugList(_ rows: [[String: Any]]) -> String {
        let parts = rows.compactMap { r -> String? in
            guard let id = r["id"] as? Int, let app = r["app"] as? String, app == "Finder" else { return nil }
            return "\(id)(\((r["onscreen"] as? Bool) == true ? "on" : "off")\((r["addressable"] as? Bool) == true ? "" : ",unread"))"
        }
        let line = parts.sorted().joined(separator: " ")
        defer { lastList = line }
        return line == lastList ? "=" : line
    }

    private static func size(of row: [String: Any]) -> (w: Int, h: Int)? {
        guard let f = row["frame"] as? [String: Any],
              let w = f["w"] as? Int, let h = f["h"] as? Int else { return nil }
        return (w, h)
    }
}
