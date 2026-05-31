import Foundation

// Generic JS-side observer of NSDistributedNotificationCenter. Complements
// Caffeinate (which hard-codes the lock/sleep DN names) by exposing the same
// underlying machinery for any notification name a stack wants to listen for.
// Hammerspoon's hs.distributednotifications is the reference.
enum DistributedNotifications {
    static func observe(name: String,
                        callback: @escaping ([String: Any]) -> Void) -> Token {
        let center = DistributedNotificationCenter.default()
        let observerToken = center.addObserver(
            forName: Notification.Name(name),
            object: nil, queue: .main
        ) { notif in
            var payload: [String: Any] = ["name": notif.name.rawValue]
            if let obj = notif.object as? String { payload["object"] = obj }
            if let info = notif.userInfo {
                for (k, v) in info {
                    guard let key = k as? String else { continue }
                    // Only forward JSON-able scalars. Drop NSData / arbitrary objects
                    // so jsonify doesn't choke on something WKWebView can't eval.
                    if v is String || v is NSNumber || v is Bool { payload[key] = v }
                }
            }
            callback(payload)
        }
        return Token {
            center.removeObserver(observerToken)
        }
    }
}
