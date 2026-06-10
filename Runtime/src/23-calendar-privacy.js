  // Calendar events via EventKit. First call to events()/createEvent()
  // triggers the Calendar TCC prompt (macOS 14+ asks for "Full Access" —
  // covers both reads + writes). reminders() triggers a SEPARATE Reminders
  // TCC prompt the first time it's called. Denial yields [] / null, never
  // throws.
  //   await sd.calendar.events({ from: nowSec, to: nowSec + 86400 })
  //   await sd.calendar.events({ from, to, calendarIds: ["UUID..."] })
  //   // → [{ identifier, title, start, end, allDay, calendar,
  //   //      location?, notes?, url? }, ...]
  //   await sd.calendar.list()
  //   // → [{ identifier, title, source, type, allowsModify, color? }, ...]
  //   await sd.calendar.reminders()
  //   await sd.calendar.reminders({ completed: false })   // only incomplete
  //   await sd.calendar.reminders({ completed: true })    // only completed
  //   await sd.calendar.reminders({ list: ["UUID..."] })  // specific list(s)
  //   // → [{ identifier, title, priority, completed, list,
  //   //      due?, notes? }, ...]
  //   const id = await sd.calendar.createEvent({
  //     calendarId: null,                  // null = default calendar
  //     title: "Standup", start: nowSec, end: nowSec + 1800,
  //     location: "Room 4", notes: "...", allDay: false
  //   });
  //   // → newEventId | null on failure
  //   sd.calendar.observe.subscribe(() => refetch());
  //   // Fires on every store change (this daemon, Calendar.app, Reminders,
  //   // MDM sync, …). Payload is `{ ts: epoch }` — re-fetch on signal.
  // Times are UNIX epoch seconds (Number). Reminders WRITE (createReminder)
  // is not yet shipped.
sd.calendar = {
    events(opts) {
      const o = opts || {};
      return request({
        type: "calendar.events",
        from: o.from, to: o.to,
        calendarIds: o.calendarIds
      });
    },
    list() { return request({ type: "calendar.list" }); },
    reminders(opts) {
      const o = opts || {};
      return request({
        type:      "calendar.reminders",
        list:      o.list,
        completed: o.completed
      });
    },
    createEvent(opts) {
      const o = opts || {};
      return request({
        type:       "calendar.createEvent",
        calendarId: o.calendarId,
        title:      String(o.title ?? ""),
        start:      o.start,
        end:        o.end,
        location:   o.location,
        notes:      o.notes,
        allDay:     !!o.allDay
      });
    },
    // Subscribable signal. Fires every time EventKit posts
    // EKEventStoreChanged — any app adding/editing/deleting an event or
    // reminder triggers it. Payload is a fresh `{ ts }` so the signal's
    // dedupe doesn't suppress repeat changes; subscribers re-fetch.
    //   const unsub = sd.calendar.observe.subscribe(() => refetch());
    //   // later: unsub();
    observe: channel("calendarChanged")
  };
  // "Is anything capturing my screen / mic / camera right now?" — cross-
  // references the live-capture signals macOS exposes through public APIs.
  //   const r = await sd.privacy.recording();
  //   // → { screen: [], camera: [{ device, id, inUse: true }, ...],
  //   //                  microphone: [{ device, id, inUse: true }, ...] }
  //   sd.privacy.observe.subscribe(({ camera, microphone }) => {
  //     // Fires every 2s when the active set changes (diff-pushed —
  //     // steady-state "nothing recording" doesn't refire).
  //   });
  // v1 limitations (documented):
  //  - `screen` is always [] — accurate process attribution for screen
  //    capture needs private SPI (out of scope for v1). Future v2 can
  //    populate the array without breaking the shape contract.
  //  - Camera / mic entries don't include `app` / `pid` — AVCaptureDevice
  //    + CoreAudio don't expose the owning process; resolving it would
  //    need fragile lsof / /dev walks. v1 surfaces the per-device boolean
  //    only. v2 may add app attribution once a stable signal exists.
  // Reading does NOT trigger camera / microphone TCC prompts (no stream
  // is opened — pure property reads on the device enumeration).
sd.privacy = {
    recording() { return request({ type: "privacy.recording" }); },
    observe: channel("privacy")
  };
  // Paired Bluetooth peripherals via IOBluetooth. Triggers the Bluetooth
  // TCC prompt on first use.
  //   const devices = await sd.bluetooth.paired();
  //   // → [{ address, connected, name?, classOfDevice?, services?:
  //   //      ["Hands-Free Audio Gateway", "A2DP", ...] }, ...]
  // `services` differentiates AirPods (audio sink + handset) from generic
  // controllers without you having to decode classOfDevice bits.
  // Battery levels (AirPods left/right/case, mouse %) are not yet exposed —
  // those need per-device-class private SPI (separate follow-up).
sd.bluetooth = {
    paired() { return request({ type: "bluetooth.paired" }); }
  };
