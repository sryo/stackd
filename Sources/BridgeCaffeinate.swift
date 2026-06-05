import Foundation
import IOKit.pwr_mgt  // IOPMAssertionID — used by sd.caffeinate.assert / .release

/// Caffeinate (wake-lock) primitive group — extracted from Bridge.swift as
/// part of the god-object breakup continuation (follow-up to A1). Two
/// entries:
///
///   - `caffeinate.assert` — mints an IOPMAssertion held until release.
///     Three JS types map to three IOPM assertion strings — see
///     `Caffeinate.assert(type:reason:)`. Returns a per-bridge handle id;
///     JS wraps it as `{ id, release() }`. IPC envelope's `type` key is
///     reserved for primitive dispatch, so the assertion kind travels under
///     `assertionType` (matches the bonjour.publish/serviceType workaround).
///
///   - `caffeinate.release` — releases one held assertion by handle id.
///
/// `caffeinateAssertions` and `nextCaffeinateId` were widened from
/// fileprivate to internal in Bridge.swift so this file's `.custom` /
/// `.syncBridge` closures can mint and release `IOPMAssertionID`s. Scope
/// drain on stack unload (end of Bridge.swift) releases every outstanding
/// assertion so a forgotten wake-lock can't outlive the stack.
extension Bridge {
    /// Caffeinate primitives — concatenated into `Bridge.primitives`
    /// alongside the rest of the inline registrations. Pure builder; no
    /// side effects.
    static func caffeinatePrimitives() -> [Primitive] {
        return [
            // Mints an IOPMAssertion held until release. Three JS types map
            // to three IOPM assertion strings — see Caffeinate.assert(type:
            // reason:). Returns a per-bridge handle id; JS wraps it as
            // { id, release() }. Stack unload drains every outstanding
            // assertion via scope so a forgotten wake-lock can't outlive
            // the stack. Permission: "caffeinate".
            .custom("caffeinate.assert", permission: "caffeinate") { bridge, body, requestId in
                // The IPC envelope already owns the "type" key (used to dispatch
                // to this primitive), so the assertion kind comes in on
                // "assertionType" — JS api.js renames spec.type accordingly.
                let kind = body["assertionType"] as? String ?? ""
                let reason = body["reason"] as? String ?? ""
                guard let assertionId = Caffeinate.assert(type: kind, reason: reason) else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                let id = bridge.nextCaffeinateId
                bridge.nextCaffeinateId += 1
                bridge.caffeinateAssertions[id] = assertionId
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("caffeinate.release", permission: "caffeinate", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let assertionId = b.caffeinateAssertions.removeValue(forKey: id) else { return false }
                return Caffeinate.release(id: assertionId)
            },
        ]
    }
}
