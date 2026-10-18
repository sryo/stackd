import AppKit
import CoreGraphics
import Foundation

// MARK: ============================================================
// MARK: Gesture — AppKit gesture-event decoding
// MARK: ============================================================

// Read-side decoding of trackpad gestures observed through a CGEventTap.
// CGEventType 29 = NSEventTypeGesture (private). NSEvent.subtype gives us
// the gesture kind (rotate/magnify/swipe/begin/end), and NSEvent.touches
// gives us live finger positions/phases. This is the path TTTaps used to
// dispatch 3/4/5-finger taps and drags.

enum Gesture {

    /// Private CGEventType for gesture-class events. Numeric value 29.
    static let cgEventType = CGEventType(rawValue: 29)!

    // Private gesture CGEventFields (layout from the vendored TouchEvents.c
    // synthesizer): 110 gesture HID subtype, 113 magnification (float, the
    // per-event scale delta NSEvent.magnification reports), 114 rotation
    // (float, degrees), 115 swipe direction bits, 132 IOHIDEventPhaseBits.
    private static let subtypeField        = CGEventField(rawValue: 110)!
    private static let magnificationField  = CGEventField(rawValue: 113)!
    private static let rotationField       = CGEventField(rawValue: 114)!
    private static let swipeDirectionField = CGEventField(rawValue: 115)!
    private static let phaseField          = CGEventField(rawValue: 132)!

    /// Motion values of one gesture event, read straight off the CGEvent so
    /// no NSEvent accessor can throw for a mismatched subtype. Always has
    /// `gesturePhase`; `magnification` only on magnify, `rotation` only on
    /// rotate, `swipeDirection` only on swipe.
    static func motion(cgEvent: CGEvent) -> [String: Any] {
        let subtype = cgEvent.getIntegerValueField(subtypeField)
        var m: [String: Any] = [
            "gesturePhase": ScrollWheel.phaseName(cgEvent.getIntegerValueField(phaseField))
        ]
        switch subtype {
        case 0x08:
            m["magnification"] = cgEvent.getDoubleValueField(magnificationField)
        case 0x05:
            m["rotation"] = cgEvent.getDoubleValueField(rotationField)
        case 0x10:
            switch cgEvent.getIntegerValueField(swipeDirectionField) {
            case 1:  m["swipeDirection"] = "up"
            case 2:  m["swipeDirection"] = "down"
            case 4:  m["swipeDirection"] = "left"
            case 8:  m["swipeDirection"] = "right"
            default: break
            }
        default:
            break
        }
        return m
    }

    static func describe(cgEvent: CGEvent) -> [String: Any]? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        let subtype = Int(nsEvent.subtype.rawValue)

        // Per-touch detail for TTTaps-class consumers: stable identity, phase,
        // normalized position (0–1 trackpad-relative). Walk .any to include
        // .ended / .cancelled touches alongside the live ones; the live ones
        // (began/moved/stationary) are the fingers currently on the trackpad.
        let touchesAll = nsEvent.touches(matching: .any, in: nil)
        var touches: [[String: Any]] = []
        var phases: [String: Int] = [:]
        var fingers = 0
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
            if touching { fingers += 1 }
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

        var out: [String: Any] = [
            "subtype": subtype,
            "subtypeName": subtypeName(subtype),
            "fingers": fingers,
            "phases": phases,
            "touches": touches
        ]
        for (k, v) in motion(cgEvent: cgEvent) { out[k] = v }
        return out
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

// MARK: ============================================================
// MARK: ScrollWheel — scroll-event field decoding
// MARK: ============================================================

// CoreGraphics private SPI. CGEventCopyIOHIDEvent returns the IOHIDEvent a
// CGEvent was built from (+1, nil for synthesized events);
// IOHIDEventGetSenderID returns the IORegistry entry ID of the HID service
// that produced it, which is the same ID for every scroll, momentum and
// gesture event of one physical device.
@_silgen_name("CGEventCopyIOHIDEvent")
private func CGEventCopyIOHIDEvent(_ event: CGEvent) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetSenderID")
private func IOHIDEventGetSenderID(_ event: CFTypeRef) -> UInt64

enum ScrollWheel {

    /// Raw scroll fields of one scrollWheel CGEvent. Axis 1 is vertical and
    /// axis 2 horizontal; signs are the raw CoreGraphics values, so they
    /// already include the user's natural-scrolling preference.
    struct Fields: Equatable {
        var pointDeltaX: Double
        var pointDeltaY: Double
        var fixedDeltaX: Double
        var fixedDeltaY: Double
        /// CGScrollPhase: 1 began, 2 changed, 4 ended, 8 cancelled,
        /// 128 mayBegin. 0 for wheel mice and momentum events.
        var phase: Int64
        /// CGMomentumScrollPhase: 0 none, 1 begin, 2 continue, 3 end.
        var momentumPhase: Int64
        var isContinuous: Bool
        /// HID sender (0 = unknown / synthesized).
        var senderId: UInt64
    }

    static func read(_ event: CGEvent) -> Fields {
        Fields(
            pointDeltaX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            pointDeltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixedDeltaX: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            fixedDeltaY: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            senderId: senderId(of: event))
    }

    static func senderId(of event: CGEvent) -> UInt64 {
        guard let hid = CGEventCopyIOHIDEvent(event)?.takeRetainedValue() else { return 0 }
        return IOHIDEventGetSenderID(hid)
    }

    /// Payload keys merged into a scrollWheel eventtap callback.
    static func payload(_ f: Fields) -> [String: Any] {
        [
            "deltaX": f.pointDeltaX,
            "deltaY": f.pointDeltaY,
            "fixedDeltaX": f.fixedDeltaX,
            "fixedDeltaY": f.fixedDeltaY,
            "scrollPhase": phaseName(f.phase),
            "momentumPhase": momentumPhaseName(f.momentumPhase),
            "isContinuous": f.isContinuous,
            "senderId": f.senderId == 0 ? NSNull() : f.senderId as Any
        ]
    }

    static func phaseName(_ raw: Int64) -> String {
        switch raw {
        case 0:   return "none"
        case 1:   return "began"
        case 2:   return "changed"
        case 4:   return "ended"
        case 8:   return "cancelled"
        case 128: return "mayBegin"
        default:  return "unknown"
        }
    }

    static func momentumPhaseName(_ raw: Int64) -> String {
        switch raw {
        case 0:  return "none"
        case 1:  return "began"
        case 2:  return "changed"
        case 3:  return "ended"
        default: return "unknown"
        }
    }
}

/// A stack's claim on the current trackpad scroll session. While held, the
/// consuming tap swallows the session's remaining scroll events and its
/// momentum tail; the next scroll that begins a new gesture passes through
/// and ends the claim. `senderId == nil` claims every trackpad sender.
struct ScrollClaim: Equatable {
    enum Decision: Equatable {
        case pass
        case swallow
        /// Pass the event and drop the claim.
        case release
    }

    var senderId: UInt64?
    var owner: String

    /// A sender-scoped claim takes every continuous event of that sender,
    /// including phase-less ones posted around a gesture; a wildcard claim
    /// takes only phased or momentum events, whatever their sender. Discrete
    /// wheel events and events of other senders always pass. `mayBegin` can
    /// interleave with a momentum tail, so only `began` ends the claim.
    static func decide(claim: ScrollClaim?, _ f: ScrollWheel.Fields) -> Decision {
        guard let claim = claim else { return .pass }
        let phased = f.phase != 0 || f.momentumPhase != 0
        if let sender = claim.senderId {
            guard f.senderId == sender, phased || f.isContinuous else { return .pass }
        } else {
            guard phased else { return .pass }
        }
        return f.phase == 1 ? .release : .swallow
    }
}
