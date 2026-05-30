import AppKit

// Read-side decoding of trackpad gestures observed through a CGEventTap.
// CGEventType 29 = NSEventTypeGesture (private). NSEvent.subtype gives us
// the gesture kind (rotate/magnify/swipe/begin/end), and NSEvent.touches
// gives us live finger positions/phases. This is the path TTTaps used to
// dispatch 3/4/5-finger taps and drags.

enum Gesture {

    /// Private CGEventType for gesture-class events. Numeric value 29.
    static let cgEventType = CGEventType(rawValue: 29)!

    static func describe(cgEvent: CGEvent) -> [String: Any]? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        let subtype = Int(nsEvent.subtype.rawValue)

        // All touches currently on the trackpad (began/moved/stationary).
        let touchingSet = nsEvent.touches(matching: .touching, in: nil)
        let fingers = touchingSet.count

        // Per-touch detail for TTTaps-class consumers: stable identity, phase,
        // normalized position (0–1 trackpad-relative). Walk .any to include
        // .ended / .cancelled touches alongside the live ones.
        let touchesAll = nsEvent.touches(matching: .any, in: nil)
        var touches: [[String: Any]] = []
        var phases: [String: Int] = [:]
        for t in touchesAll {
            let phaseName: String
            switch t.phase {
            case .began:      phaseName = "began"
            case .moved:      phaseName = "moved"
            case .stationary: phaseName = "stationary"
            case .ended:      phaseName = "ended"
            case .cancelled:  phaseName = "cancelled"
            default:          phaseName = "other"
            }
            phases[phaseName, default: 0] += 1
            // .identity is an opaque NSCopying; String(describing:) yields a
            // stable repr that's unique per finger within the gesture lifetime —
            // same approach Hammerspoon uses for hs.eventtap touch identity.
            let id = String(describing: t.identity)
            // .touching covers began/moved/stationary; consumers checking the
            // count of "live" touches per-event mirror Hammerspoon's
            // touchCount = #event:getTouches().
            let touching = (t.phase == .began || t.phase == .moved || t.phase == .stationary)
            touches.append([
                "identity":  id,
                "phase":     phaseName,
                "touching":  touching,
                "normalizedPosition": [
                    "x": Double(t.normalizedPosition.x),
                    "y": Double(t.normalizedPosition.y)
                ]
            ])
        }

        return [
            "subtype": subtype,
            "subtypeName": subtypeName(subtype),
            "fingers": fingers,
            "phases": phases,
            "touches": touches
        ]
    }

    private static func subtypeName(_ s: Int) -> String {
        // Values from TouchEvents.h:
        //   0x05 rotate, 0x08 magnify, 0x0B gesture, 0x10 swipe,
        //   0x16 smartMagnify, 0x3D beginGesture, 0x3E endGesture
        switch s {
        case 0x05: return "rotate"
        case 0x08: return "magnify"
        case 0x0B: return "gesture"
        case 0x10: return "swipe"
        case 0x16: return "smartMagnify"
        case 0x3D: return "beginGesture"
        case 0x3E: return "endGesture"
        default:   return "subtype-\(s)"
        }
    }
}
