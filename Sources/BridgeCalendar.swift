import Foundation

/// `sd.calendar.*` primitives — EventKit wrappers gated by `"calendar"`.
/// Each `.custom` entry hops onto the main thread via the EventKit
/// callback before responding because EventKit dispatches to whichever
/// queue requested access, which isn't always main.
///
/// First call to events() / reminders() triggers the full-access TCC
/// prompt (single prompt covers reads + writes; createEvent() doesn't
/// re-prompt). list() reads cached calendar metadata without prompting.
extension Bridge {
    static func calendarPrimitives() -> [Primitive] { [
        // Range query, optionally restricted to specific calendars
        // (default = all). Returns [] on denial, never nil.
        .custom("calendar.events", permission: "calendar") { bridge, body, requestId in
            let from = (body["from"] as? Double) ?? 0
            let to   = (body["to"]   as? Double) ?? 0
            let ids  = body["calendarIds"] as? [String]
            Calendar.events(from: from, to: to, calendarIds: ids) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? [[String: Any]]())
            }
        },
        .custom("calendar.list", permission: "calendar") { bridge, _, requestId in
            Calendar.calendars { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? [[String: Any]]())
            }
        },
        // Reminders — first call triggers the Reminders TCC prompt
        // (separate bucket from Calendar's). `list` filters to specific
        // reminder-list identifiers. `completed`: nil → both,
        // false → only incomplete, true → only completed. Returns [] on
        // denial, never nil.
        .custom("calendar.reminders", permission: "calendar") { bridge, body, requestId in
            let listIds   = body["list"]      as? [String]
            let completed = body["completed"] as? Bool
            Calendar.reminders(listIds: listIds, completed: completed) { [weak bridge] result in
                bridge?.respond(requestId: requestId, value: result as Any? ?? [[String: Any]]())
            }
        },
        // Create an event in `calendarId` (nil → default calendar for new
        // events). Returns the new event's identifier on success, null on
        // failure (denied access, missing calendar, save error). No new
        // TCC prompt — the Calendar full-access tier covers writes too.
        .custom("calendar.createEvent", permission: "calendar") { bridge, body, requestId in
            let calId    = body["calendarId"] as? String
            let title    = body["title"]      as? String ?? ""
            let start    = (body["start"]     as? Double) ?? 0
            let end      = (body["end"]       as? Double) ?? 0
            let location = body["location"]   as? String
            let notes    = body["notes"]      as? String
            let allDay   = (body["allDay"]    as? Bool) ?? false
            Calendar.createEvent(
                calendarId: calId,
                title:      title,
                start:      start,
                end:        end,
                location:   location,
                notes:      notes,
                allDay:     allDay
            ) { [weak bridge] id in
                bridge?.respond(requestId: requestId, value: id as Any? ?? NSNull())
            }
        }
    ] }
}
