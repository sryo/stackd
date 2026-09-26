import CoreGraphics
import EventKit
import Foundation

// Tests for the pure helpers in `Calendar` — the imperative
// events()/reminders()/createEvent() paths can't be tested in isolation
// (they hit a live EKEventStore + TCC), but the dict-shape mappers and
// the calendar-id filtering helper are pure and form the bug surface for
// JS callers consuming the payloads.
//
// CLAUDE.md says "you can't test everything — focus on critical paths."
// The critical path here is the JSON shape contract: stacks rendering
// agenda views break the moment a key disappears or changes type. Pinning
// the shape with these tests catches accidental dict mutations before they
// hit production.

func registerCalendarTests() {
    test("describe(EKEvent) emits required keys with the expected types") {
        let store = EKEventStore()
        let ev = EKEvent(eventStore: store)
        ev.title     = "Standup"
        ev.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        ev.endDate   = Date(timeIntervalSince1970: 1_700_001_800)
        ev.isAllDay  = false

        let d = Calendar.describe(ev)
        // Required (always-present) keys.
        try expectEqual(d["title"]  as? String, "Standup")
        try expectEqual(d["start"]  as? TimeInterval, 1_700_000_000)
        try expectEqual(d["end"]    as? TimeInterval, 1_700_001_800)
        try expectEqual(d["allDay"] as? Bool, false)
        // identifier is "" on an unsaved event — present, not nil.
        try expect(d["identifier"] is String)
        // calendar is "" when no calendar assigned — present, not nil.
        try expect(d["calendar"] is String)
    }

    test("describe(EKEvent) omits optional keys when their source is empty") {
        let store = EKEventStore()
        let ev = EKEvent(eventStore: store)
        ev.title     = "Bare"
        ev.startDate = Date(timeIntervalSince1970: 0)
        ev.endDate   = Date(timeIntervalSince1970: 0)
        // No location, no notes, no url, no calendar.

        let d = Calendar.describe(ev)
        try expect(d["location"] == nil, "empty location should drop the key")
        try expect(d["notes"]    == nil, "empty notes should drop the key")
        try expect(d["url"]      == nil, "missing url should drop the key")
    }

    test("describe(EKEvent) includes optional keys when populated") {
        let store = EKEventStore()
        let ev = EKEvent(eventStore: store)
        ev.title     = "Coffee"
        ev.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        ev.endDate   = Date(timeIntervalSince1970: 1_700_001_800)
        ev.location  = "Room 4"
        ev.notes     = "bring laptop"
        ev.url       = URL(string: "https://example.com/meet")

        let d = Calendar.describe(ev)
        try expectEqual(d["location"] as? String, "Room 4")
        try expectEqual(d["notes"]    as? String, "bring laptop")
        try expectEqual(d["url"]      as? String, "https://example.com/meet")
    }

    test("describe(EKReminder) emits required keys with the expected types") {
        let store = EKEventStore()
        let r = EKReminder(eventStore: store)
        r.title    = "Buy milk"
        r.priority = 5
        // isCompleted defaults to false on a fresh reminder.

        let d = Calendar.describe(r)
        try expectEqual(d["title"]     as? String, "Buy milk")
        try expectEqual(d["priority"]  as? Int,    5)
        try expectEqual(d["completed"] as? Bool,   false)
        // identifier is always present (assigned at init time on macOS).
        try expect(d["identifier"] is String)
        try expect(d["list"]       is String)
    }

    test("describe(EKReminder) drops optional keys when their source is empty") {
        let store = EKEventStore()
        let r = EKReminder(eventStore: store)
        r.title = "Bare"
        // No dueDateComponents, no notes.

        let d = Calendar.describe(r)
        try expect(d["due"]   == nil, "no due date should drop the key")
        try expect(d["notes"] == nil, "empty notes should drop the key")
    }

    test("describe(EKReminder) includes due when dueDateComponents resolves") {
        let store = EKEventStore()
        let r = EKReminder(eventStore: store)
        r.title = "Pay rent"
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 1
        comps.hour = 9;    comps.minute = 0
        r.dueDateComponents = comps

        let d = Calendar.describe(r)
        // Components carry no time zone, so they resolve in the host's
        // local zone — compute the expected epoch the same way.
        let expected = Foundation.Calendar.current.date(from: comps)!.timeIntervalSince1970
        try expectEqual(d["due"] as? TimeInterval, expected)
    }

    test("filteredCalendars returns nil for nil or empty ids — predicate sees all calendars") {
        // The predicate factories on EKEventStore treat `nil` as "every
        // calendar I have access to." JS callers pass nil/empty `calendarIds`
        // to opt out of filtering — guard that the helper agrees (and never
        // returns [] which would match nothing).
        try expect(Calendar.filteredCalendars(ids: nil, entityType: .event) == nil,
                   "nil ids should yield nil (search all)")
        try expect(Calendar.filteredCalendars(ids: [], entityType: .reminder) == nil,
                   "empty ids should yield nil (search all)")
    }

    test("sourceTypeName maps every well-known EKSourceType case") {
        // Compile-time pin so a future EKSourceType case forces an explicit
        // mapping decision rather than silently falling into "unknown".
        try expectEqual(Calendar.sourceTypeName(.local),      "local")
        try expectEqual(Calendar.sourceTypeName(.exchange),   "exchange")
        try expectEqual(Calendar.sourceTypeName(.calDAV),     "caldav")
        try expectEqual(Calendar.sourceTypeName(.mobileMe),   "mobileme")
        try expectEqual(Calendar.sourceTypeName(.subscribed), "subscribed")
        try expectEqual(Calendar.sourceTypeName(.birthdays),  "birthdays")
    }

    test("colorHex renders an RGB CGColor as #RRGGBB, dropping alpha") {
        // 0.5 * 255 = 127.5 rounds to 128 (0x80).
        let c = CGColor(srgbRed: 1.0, green: 0.5, blue: 0.0, alpha: 0.3)
        try expectEqual(Calendar.colorHex(c), "#FF8000")
        try expect(Calendar.colorHex(nil) == nil, "nil color should yield nil")
    }
}
