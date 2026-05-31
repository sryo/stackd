import Foundation
import Vision

// VNGenerateImageFeaturePrintRequest — Vision's perceptual hash. Returns a
// vector of ~768 floats per image; two prints can be compared with Apple's
// VNFeaturePrintObservation.computeDistance for similarity search and
// de-duplication.
//
// Wire shape:
//   Vision.featurePrint(image:) returns a base64 NSKeyedArchiver blob of
//   the full VNFeaturePrintObservation. JS stashes it (in SQLite, JSON, …)
//   and later hands two blobs back to Vision.featurePrintDistance to get a
//   single Float distance — lower is more similar. Wrapping the whole
//   observation (not just the raw float bytes) lets us round-trip element
//   type/count safely; the raw .data buffer alone isn't reconstructible
//   into a VNFeaturePrintObservation through any public initializer.
//
// Consumers — "find similar screenshots" (DigUp's near-dup detector), photo
// library clustering, fingerprinting webcam stills to detect "user left the
// desk." Cheap enough to run at multi-Hz over camera frames once a future
// sd.camera.frame() primitive lands.

extension Vision {
    /// Compute a perceptual feature print. Returns
    ///   { print: base64, elementCount: N, elementType: "float"|"double" }
    /// or nil if the image can't be decoded.
    static func featurePrint(image source: Any?,
                             completion: @escaping ([String: Any]?) -> Void) {
        guard let cgImage = decodeImage(source) else {
            completion(nil); return
        }

        let request = VNGenerateImageFeaturePrintRequest { request, _ in
            guard let observation = (request.results as? [VNFeaturePrintObservation])?.first else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            do {
                let archived = try NSKeyedArchiver.archivedData(
                    withRootObject: observation,
                    requiringSecureCoding: true
                )
                let payload: [String: Any] = [
                    "print":        archived.base64EncodedString(),
                    "elementCount": observation.elementCount,
                    "elementType":  elementTypeName(observation.elementType)
                ]
                DispatchQueue.main.async { completion(payload) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// Compare two feature prints (both base64 NSKeyedArchiver blobs from
    /// Vision.featurePrint). Returns `{ distance: Float }` — lower means
    /// more similar; identical images return ~0. Returns nil if either blob
    /// fails to unarchive or the two prints aren't comparable (different
    /// element type/count — Vision raises on mismatch).
    static func featurePrintDistance(a: String?, b: String?) -> [String: Any]? {
        guard let a = a, let b = b,
              let aData = Data(base64Encoded: a),
              let bData = Data(base64Encoded: b) else { return nil }
        do {
            let aObs = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: aData)
            let bObs = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: bData)
            guard let aObs = aObs, let bObs = bObs else { return nil }
            var distance: Float = 0
            try aObs.computeDistance(&distance, to: bObs)
            return ["distance": Double(distance)]
        } catch {
            return nil
        }
    }

    private static func elementTypeName(_ t: VNElementType) -> String {
        switch t {
        case .float:   return "float"
        case .double:  return "double"
        default:       return "unknown"
        }
    }
}
