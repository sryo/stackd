import AppKit

// MARK: - Haptic (Force Touch trackpad feedback)

// Fire-and-forget clicks on the Force Touch trackpad's Taptic Engine via the
// public NSHapticFeedbackManager. The engine only moves while a finger is on
// the trackpad, and the user's "Force Click and haptic feedback" setting can
// soften or mute it; neither is reported back, so perform() returns true
// once the request is handed off, not once it's felt.

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

    static func perform(_ name: String?) -> Bool {
        guard let p = pattern(named: name) else { return false }
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
        return true
    }
}
