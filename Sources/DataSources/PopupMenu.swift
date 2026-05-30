import AppKit

// Native NSMenu popup at the current cursor location. Builds an NSMenu from
// a declarative spec (id/title/checked/enabled/separator/submenu) and resolves
// with the id of whatever the user clicked, or null on cancel.
//
// Why native: a web modal can't escape the WebView's z-order, and a CSS
// "context menu" doesn't get the system font / hit-testing / kbd nav.
enum PopupMenu {
    static func present(items: [[String: Any]], completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let coordinator = Coordinator(completion: completion)
            let menu = build(items: items, coordinator: coordinator)
            coordinator.menu = menu

            // popUpMenu(positioning:atLocation:inView:) is the no-event-needed
            // path that works from a background process. nil view → screen coords.
            let loc = NSEvent.mouseLocation
            DispatchQueue.main.async {
                let chose = menu.popUp(positioning: nil, at: loc, in: nil)
                if !chose {
                    coordinator.fire(nil)
                }
                // Hold the coordinator alive long enough for action callbacks
                // to fire on the main runloop.
                _ = coordinator
            }
        }
    }

    private static func build(items: [[String: Any]], coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for spec in items {
            if (spec["separator"] as? Bool) == true {
                menu.addItem(.separator())
                continue
            }
            let title = spec["title"] as? String ?? ""
            let item = NSMenuItem(title: title, action: #selector(Coordinator.picked(_:)), keyEquivalent: "")
            item.target = coordinator
            item.representedObject = spec["id"] as? String
            if let checked = spec["checked"] as? Bool, checked { item.state = .on }
            if let enabled = spec["enabled"] as? Bool, !enabled { item.isEnabled = false }
            if let sub = spec["submenu"] as? [[String: Any]] {
                item.submenu = build(items: sub, coordinator: coordinator)
                item.action = nil
                item.target = nil
            }
            menu.addItem(item)
        }
        return menu
    }

    final class Coordinator: NSObject {
        let completion: (String?) -> Void
        var fired = false
        var menu: NSMenu?
        init(completion: @escaping (String?) -> Void) { self.completion = completion }

        func fire(_ id: String?) {
            guard !fired else { return }
            fired = true
            completion(id)
        }

        @objc func picked(_ sender: NSMenuItem) {
            fire(sender.representedObject as? String)
        }
    }
}
