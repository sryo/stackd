import EventKit
import Foundation

// Calendar events via EventKit. v1 shipped read-only one-shot range query;
// v1.1 adds reminders read, event creation, and a live store-change channel
// — the three deferrals listed in the original file header.
//
// TCC: events() / createEvent() use the unified `requestFullAccessToEvents`
// path (macOS 14+) or `requestAccess(to: .event)` (macOS 13). Full access
// covers writes, so createEvent does NOT trigger a second prompt on top of
// events(). Reminders are a SEPARATE TCC bucket — first call to reminders()
// triggers the Reminders prompt via `requestFullAccessToReminders` (14+) /
// `requestAccess(to: .reminder)` (13). Denial returns [], not nil, so JS
// callers distinguish "no items" from "couldn't decode the response."
//
// The store-change channel piggybacks on `EKEventStore.eventStoreChanged`
// NotificationCenter posts — Apple's docs note the userInfo dict is empty,
// so we just signal "something moved" and let JS re-fetch. The
// CalendarObserver subclass uses the standard RefCountedObserver lifecycle
// so the listener is only installed while at least one stack subscribes.
//
// Daemon-vs-stack check: EventKit isn't reachable from JS without these
// primitives. Reminders write (createReminder) is deliberately not shipped
// in this PR — it needs its own surface and its own TCC story validation.

enum Calendar {
    // One shared store per process. EKEventStore caches calendar metadata
    // internally and is cheap to keep alive; reinstantiating it per call
    // would discard the cache. Same store services events + reminders +
    // the change-notification observer — the TCC gates are per-entity-type,
    // not per-store.
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
            let calendars = filteredCalendars(ids: calendarIds, entityType: .event)
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
                describeCalendar(cal)
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Reminders — `[{ identifier, title, due?, priority, completed, list, notes? }]`.
    /// `list` filters to specific reminder-list (EKCalendar of type .reminder)
    /// identifiers; nil/empty searches every reminder list. `completed`:
    ///   nil   — return both completed and incomplete (default)
    ///   false — only incomplete
    ///   true  — only completed
    /// Completion always fires on the main queue. Triggers the Reminders TCC
    /// prompt on first use (separate prompt from Calendar's).
    static func reminders(listIds: [String]?,
                          completed: Bool?,
                          completion: @escaping ([[String: Any]]?) -> Void) {
        requestRemindersAccess { granted in
            guard granted else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let calendars = filteredCalendars(ids: listIds, entityType: .reminder)
            // EKEventStore has three predicate flavors:
            //   incompleteReminders(withDueDateStarting:ending:calendars:)
            //   completedReminders(withCompletionDateStarting:ending:calendars:)
            //   predicateForReminders(in:)                  — both, every reminder
            // We pass nil for the date bounds so the "incomplete" / "completed"
            // predicates aren't restricted by due date (callers can filter the
            // returned array client-side if they want a date window).
            let predicate: NSPredicate
            switch completed {
            case .some(true):
                predicate = store.predicateForCompletedReminders(
                    withCompletionDateStarting: nil, ending: nil, calendars: calendars)
            case .some(false):
                predicate = store.predicateForIncompleteReminders(
                    withDueDateStarting: nil, ending: nil, calendars: calendars)
            case .none:
                predicate = store.predicateForReminders(in: calendars)
            }
            // fetchReminders is async and delivers on an arbitrary queue; hop
            // to main so the completion contract matches events() / calendars().
            store.fetchReminders(matching: predicate) { items in
                let out = (items ?? []).map { describe($0) }
                DispatchQueue.main.async { completion(out) }
            }
        }
    }

    /// Create a new event. Returns the new EKEvent's `eventIdentifier` on
    /// success, nil on any failure (denied access, missing calendar, save
    /// error). Completion fires on the main queue. `calendarId` nil uses
    /// `store.defaultCalendarForNewEvents`. `allDay` defaults to false.
    /// `start` / `end` are UNIX epoch seconds.
    static func createEvent(calendarId: String?,
                            title: String,
                            start: TimeInterval,
                            end: TimeInterval,
                            location: String?,
                            notes: String?,
                            allDay: Bool,
                            completion: @escaping (String?) -> Void) {
        requestAccess { granted in
            guard granted else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Calendar pick: explicit id → look up; nil → default. Either may
            // resolve to nil (default missing on a fresh install with no
            // writable calendar), in which case save() would crash with an
            // assertion — guard early and return nil instead.
            let target: EKCalendar?
            if let id = calendarId, !id.isEmpty {
                target = store.calendars(for: .event)
                    .first { $0.calendarIdentifier == id }
            } else {
                target = store.defaultCalendarForNewEvents
            }
            guard let cal = target else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let ev = EKEvent(eventStore: store)
            ev.calendar  = cal
            ev.title     = title
            ev.startDate = Date(timeIntervalSince1970: start)
            ev.endDate   = Date(timeIntervalSince1970: end)
            ev.isAllDay  = allDay
            if let location = location, !location.isEmpty { ev.location = location }
            if let notes    = notes,    !notes.isEmpty    { ev.notes    = notes    }
            do {
                try store.save(ev, span: .thisEvent)
                let id = ev.eventIdentifier
                DispatchQueue.main.async { completion(id) }
            } catch {
                FileHandle.standardError.write(Data(
                    "stackd: Calendar.createEvent — save failed: \(error.localizedDescription)\n".utf8))
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// macOS 14+ split read access from write access via
    /// requestFullAccessToEvents / requestWriteOnlyAccessToEvents. macOS 13
    /// still uses requestAccess(to:). We need read for events() to work, so
    /// always go through the full-access path — which also covers writes for
    /// createEvent() (no second prompt).
    private static func requestAccess(_ done: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in done(granted) }
        }
    }

    /// Separate TCC bucket from events — macOS 14+ uses
    /// requestFullAccessToReminders; macOS 13 falls back to the unified
    /// requestAccess(to: .reminder). First call to reminders() triggers
    /// the Reminders prompt; events() doesn't (and vice versa).
    private static func requestRemindersAccess(_ done: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .reminder) { granted, _ in done(granted) }
        }
    }

    /// Translate optional id-filter into the EKCalendar array EventKit's
    /// predicate factories expect: nil → "all calendars I can see", non-empty
    /// → only those whose identifier matches. An id that doesn't resolve is
    /// silently dropped (matches the events() v1 behavior).
    static func filteredCalendars(ids: [String]?, entityType: EKEntityType) -> [EKCalendar]? {
        guard let ids = ids, !ids.isEmpty else { return nil }
        let all = store.calendars(for: entityType)
        return all.filter { ids.contains($0.calendarIdentifier) }
    }

    /// Pure mapper: EKEvent → JSON-able dict. Pulled out for direct test
    /// coverage of the shape contract — the imperative events()/createEvent()
    /// paths can't be unit-tested (TCC + live store), but the dict shape can.
    static func describe(_ e: EKEvent) -> [String: Any] {
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

    /// Pure mapper: EKReminder → JSON-able dict. Same testability rationale
    /// as describe(EKEvent). `due` is epoch seconds when the reminder has a
    /// dueDateComponents that resolves to a real date; absent otherwise.
    /// `priority` follows EventKit's 0=none / 1=high / 5=medium / 9=low scale.
    static func describe(_ r: EKReminder) -> [String: Any] {
        var d: [String: Any] = [
            "identifier": r.calendarItemIdentifier,
            "title":      r.title ?? "",
            "priority":   r.priority,
            "completed":  r.isCompleted,
            "list":       r.calendar?.title ?? ""
        ]
        if let comps = r.dueDateComponents,
           let date = Foundation.Calendar.current.date(from: comps) {
            d["due"] = date.timeIntervalSince1970
        }
        if let notes = r.notes, !notes.isEmpty { d["notes"] = notes }
        return d
    }

    /// Pure mapper: EKCalendar → JSON-able dict. Exposed for the calendars()
    /// list path and direct test coverage of the calendar-list shape.
    static func describeCalendar(_ cal: EKCalendar) -> [String: Any] {
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

    static func sourceTypeName(_ t: EKSourceType) -> String {
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
    static func colorHex(_ color: CGColor?) -> String? {
        guard let color = color, let comps = color.components, comps.count >= 3 else { return nil }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - CalendarObserver: store-change notifications

/// Fires whenever any app (Calendar.app, Reminders, an MDM sync, this
/// daemon's own createEvent) writes to the EventKit database. EventKit
/// posts `.EKEventStoreChanged` with an empty userInfo dict; subscribers
/// re-fetch on signal rather than receiving a delta. Lazy: the NC observer
/// is only installed while at least one stack subscribes; teardown after
/// the standard 5s debounce when the last unsubscribes.
final class CalendarObserver: RefCountedObserver {
    static let shared = CalendarObserver()
    private override init() { super.init() }

    override func install() -> Token {
        // EKEventStoreChanged is posted by the EventKit framework on the
        // default NotificationCenter (not NSWorkspace's). Same shape as
        // FrontmostAppObserver — one notification name, no per-spec side
        // effect, just fan out to subscribers via fire().
        installNotifications([
            (NotificationCenter.default, .EKEventStoreChanged)
        ])
    }
}
