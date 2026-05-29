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

        // Phase counts for debugging / TTTaps-style tap-vs-drag classification.
        let touchesAll = nsEvent.touches(matching: .any, in: nil)
        var phases: [String: Int] = [:]
        for t in touchesAll {
            let name: String
            switch t.phase {
            case .began:      name = "began"
            case .moved:      name = "moved"
            case .stationary: name = "stationary"
            case .ended:      name = "ended"
            case .cancelled:  name = "cancelled"
            default:          name = "other"
            }
            phases[name, default: 0] += 1
        }

        return [
            "subtype": subtype,
            "subtypeName": subtypeName(subtype),
            "fingers": fingers,
            "phases": phases
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
