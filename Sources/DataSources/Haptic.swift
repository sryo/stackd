import AppKit

// MARK: - Haptic (Force Touch trackpad feedback)

// Fire-and-forget clicks on the Force Touch trackpad's Taptic Engine, two ways.
//
// perform() goes through the public NSHapticFeedbackManager. The engine only
// moves while macOS counts a finger as on the trackpad, and the user's "Force
// Click and haptic feedback" setting can soften or mute it; neither is
// reported back, so it returns true once the request is handed off, not once
// it's felt. A finger resting on the pad's outer edge is sometimes not
// counted, and those clicks are silently dropped.
//
// actuate() drives the actuator directly through MultitouchSupport SPI,
// which plays regardless of touch state. It takes a raw waveform ID and
// optionally the device to click (sd.touchdevice's `device`, the HID sender
// id); without one every trackpad with an actuator clicks.

enum Haptic {
    /// JS pattern names, spelled as the NSHapticFeedbackManager cases.
    /// nil (argument omitted) is "generic"; anything else unknown is nil so
    /// a typo fails loudly instead of clicking the wrong way.
    static func pattern(named name: String?) -> NSHapticFeedbackManager.FeedbackPattern? {
        switch name {
        case nil, "generic": return .generic
        case "alignment":    return .alignment
        case "levelChange":  return .levelChange
        default:             return nil
        }
    }

    /// Waveform IDs are small positive integers; anything else (fractions,
    /// strings, out of range) is rejected rather than truncated.
    static func actuationID(from value: Any?) -> Int32? {
        let n: Int
        if let i = value as? Int { n = i }
        else if let d = value as? Double, d.rounded() == d, abs(d) < 1e6 { n = Int(d) }
        else { return nil }
        return (1...255).contains(n) ? Int32(n) : nil
    }

    /// Open actuators keyed by the device's HID sender id. Main thread only
    /// (bridge handlers run there).
    private static var actuators: [UInt64: MTActuator] = [:]

    private static func openActuators() -> [UInt64: MTActuator] {
        if !actuators.isEmpty { return actuators }
        guard let list = MTDeviceCreateList() else { return [:] }
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var mtID: UInt64 = 0
            guard MTDeviceGetDeviceID(dev, &mtID) == 0,
                  let act = MTActuatorCreateFromDeviceID(mtID) else { continue }
            if MTActuatorOpen(act) == 0 {
                actuators[TouchDeviceObserver.identity(of: dev)] = act
            }
        }
        return actuators
    }

    private static func closeActuators() {
        for act in actuators.values { _ = MTActuatorClose(act) }
        actuators = [:]
    }

    /// Plays waveform `id` on `device`, or on every actuator when nil.
    /// A failed actuation (device unplugged, slept, re-enumerated) reopens
    /// the actuators once and retries. False when nothing played.
    static func actuate(_ id: Int32, device: UInt64?) -> Bool {
        for attempt in 0..<2 {
            let targets = openActuators().filter { device == nil || $0.key == device }
            if targets.isEmpty { return false }
            var played = false, failed = false
            for act in targets.values {
                if MTActuatorActuate(act, id, 0, 0, 0) == 0 { played = true } else { failed = true }
            }
            if !failed || attempt == 1 { return played }
            closeActuators()
        }
        return false
    }

    static func perform(_ name: String?) -> Bool {
        guard let p = pattern(named: name) else { return false }
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
        return true
    }
}
