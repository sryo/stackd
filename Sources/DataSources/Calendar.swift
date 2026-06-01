import EventKit
import Foundation

// Calendar events via EventKit. Read-only one-shot range query for now —
// reminders read, event creation, and live store-change observers are
// deferred follow-ups that don't change the file's TCC story (just add
// more methods on the same store).
//
// TCC: the first call to events() triggers the Calendar prompt. macOS 14+
// uses EKEventStore.requestFullAccessToEvents (the "Full Access" tier —
// Apple now distinguishes from "Write Only Access" which is for creating
// events without reading existing ones); macOS 13 uses the older
// requestAccess(to:). On denial we return an empty array, not nil, so JS
// callers can distinguish "no events" from "couldn't decode the response."
//
// Daemon-vs-stack check: EventKit isn't reachable from the JS surface —
// stackd has no primitive for the underlying EKEventStore. This is a
// genuine new primitive, not policy.

enum Calendar {
    // One shared store per process. EKEventStore caches calendar metadata
    // internally and is cheap to keep alive; reinstantiating it per call
    // would discard the cache.
    private static let store = EKEventStore()

    /// Events between `from` and `to` (UNIX epoch seconds). `calendarIds`
    /// optionally restricts to specific calendars (EKCalendar.calendarIdentifier);
    /// nil/empty searches every calendar the user has granted access to.
    /// Completion always fires on the main queue.
    static func events(from: TimeInterval,
                       to: TimeInterval,
                       calendarIds: [String]?,
                       completion: @escaping ([[String: Any]]?) -> Void) {
        requestAccess { granted in
            guard granted else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let calendars: [EKCalendar]?
            if let ids = calendarIds, !ids.isEmpty {
                let all = store.calendars(for: .event)
                calendars = all.filter { ids.contains($0.calendarIdentifier) }
            } else {
                calendars = nil
            }
            let predicate = store.predicateForEvents(
                withStart: Date(timeIntervalSince1970: from),
                end:       Date(timeIntervalSince1970: to),
                calendars: calendars
            )
            let events = store.events(matching: predicate)
            let out = events.map { describe($0) }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Calendar list — `[{ identifier, title, color, source, type, allowsModify }]`.
    /// Useful for letting users pick which calendars feed a widget.
    static func calendars(completion: @escaping ([[String: Any]]?) -> Void) {
        requestAccess { granted in
            guard granted else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let out = store.calendars(for: .event).map { (cal: EKCalendar) -> [String: Any] in
                var entry: [String: Any] = [
                    "identifier":     cal.calendarIdentifier,
                    "title":          cal.title,
                    "source":         cal.source.title,
                    "type":           sourceTypeName(cal.source.sourceType),
                    "allowsModify":   cal.allowsContentModifications
                ]
                if let hex = colorHex(cal.cgColor) { entry["color"] = hex }
                return entry
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// macOS 14+ split read access from write access via
    /// requestFullAccessToEvents / requestWriteOnlyAccessToEvents. macOS 13
    /// still uses requestAccess(to:). We need read for events() to work, so
    /// always go through the full-access path.
    private static func requestAccess(_ done: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in done(granted) }
        }
    }

    private static func describe(_ e: EKEvent) -> [String: Any] {
        var d: [String: Any] = [
            "identifier": e.eventIdentifier ?? "",
            "title":      e.title ?? "",
            "start":      e.startDate.timeIntervalSince1970,
            "end":        e.endDate.timeIntervalSince1970,
            "allDay":     e.isAllDay,
            "calendar":   e.calendar?.title ?? ""
        ]
        if let loc = e.location, !loc.isEmpty { d["location"] = loc }
        if let notes = e.notes, !notes.isEmpty { d["notes"] = notes }
        if let url = e.url?.absoluteString { d["url"] = url }
        return d
    }

    private static func sourceTypeName(_ t: EKSourceType) -> String {
        switch t {
        case .local:        return "local"
        case .exchange:     return "exchange"
        case .calDAV:       return "caldav"
        case .mobileMe:     return "mobileme"
        case .subscribed:   return "subscribed"
        case .birthdays:    return "birthdays"
        @unknown default:   return "unknown"
        }
    }

    /// CGColor → "#RRGGBB". Calendars sometimes ship with alpha < 1 and the
    /// extra channel is meaningless for display, so we drop it.
    private static func colorHex(_ color: CGColor?) -> String? {
        guard let color = color, let comps = color.components, comps.count >= 3 else { return nil }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
