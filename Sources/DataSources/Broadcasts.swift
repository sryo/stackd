import Foundation

// Generic JS-side observer of NSDistributedNotificationCenter. Listens IN for
// system / inter-process events (e.g. com.apple.screenIsLocked, app-published
// broadcasts) and forwards them to a JS callback. Complements Caffeinate
// (which hard-codes the lock/sleep DN names) by exposing the same underlying
// machinery for any notification name a stack wants to observe.
//
// Named "Broadcasts" rather than "DistributedNotifications" to avoid the
// macOS naming collision: Notify.swift sends OUT to Notification Center;
// this file listens IN to the system event bus. Different direction,
// different responsibility. Hammerspoon calls it hs.distributednotifications.
enum Broadcasts {
    static func observe(name: String,
                        callback: @escaping ([String: Any]) -> Void) -> Token {
        let center = DistributedNotificationCenter.default()
        let observerToken = center.addObserver(
            forName: Notification.Name(name),
            object: nil, queue: .main
        ) { notif in callback(payload(from: notif)) }
        return Token {
            center.removeObserver(observerToken)
        }
    }

    /// Pure Notification → JS-payload mapping. Extracted from the observer
    /// closure so the JSON-ability filter is testable without listening on
    /// the real DistributedNotificationCenter. JS consumers receive this
    /// dict via Bridge.jsonify → WKWebView eval, so anything that isn't a
    /// JSON scalar would either crash JSONSerialization (Date, raw nil) or
    /// arrive as an unhelpful "[object Object]" string. Drop them at the
    /// boundary instead.
    internal static func payload(from notif: Notification) -> [String: Any] {
        var payload: [String: Any] = ["name": notif.name.rawValue]
        if let obj = notif.object as? String { payload["object"] = obj }
        if let info = notif.userInfo {
            for (k, v) in info {
                guard let key = k as? String else { continue }
                if v is String || v is NSNumber || v is Bool { payload[key] = v }
            }
        }
        return payload
    }
}
