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
    /// app on the same Space. The addressability verdict in the row is not
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
            let mine = spacesOf(id)
            guard !mine.isEmpty,
                  matching.contains(where: { !spacesOf($0.id).isDisjoint(with: mine) }) else { continue }
            if listed[pid] == nil { listed[pid] = .some(axWindowIDs(pid)) }
            guard let inAX = listed[pid] ?? nil, !inAX.contains(id) else { continue }
            siblings.insert(id)
        }
        return siblings
    }

    private static func size(of row: [String: Any]) -> (w: Int, h: Int)? {
        guard let f = row["frame"] as? [String: Any],
              let w = f["w"] as? Int, let h = f["h"] as? Int else { return nil }
        return (w, h)
    }
}
