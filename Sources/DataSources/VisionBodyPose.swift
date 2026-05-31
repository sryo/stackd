import Foundation
import Vision

// VNDetectHumanBodyPoseRequest — 2D joint keypoints per detected body. One
// pass returns every person in the frame, each with up to 17 named joints
// (nose, eyes, ears, shoulders, elbows, wrists, hips, knees, ankles, plus
// the root).
//
// Consumers — webcam-driven posture coaching, gesture-controlled UIs
// ("raise hand to pause music"), motion capture / streaming overlays. Pairs
// with sd.display.snapshot for stills today; ideal target for a future
// sd.camera.frame() primitive emitting frames at 10-30 Hz.

extension Vision {
    /// image: dataURL or absolute path. Returns
    ///   { bodies: [{ joints: { name: { x, y, confidence }, ... },
    ///                confidence }] }
    /// Joint coordinates are web-style top-left origin in 0..1 (y-flipped).
    /// A joint is omitted from the dict if Vision's per-joint confidence is
    /// below 0.1 — under that threshold the position is effectively noise.
    /// `confidence` on the body itself is Vision's overall detection score.
    static func bodyPose(image source: Any?,
                         completion: @escaping ([String: Any]?) -> Void) {
        guard let cgImage = decodeImage(source) else {
            completion(nil); return
        }

        let request = VNDetectHumanBodyPoseRequest { request, _ in
            let observations = (request.results as? [VNHumanBodyPoseObservation]) ?? []
            var bodies: [[String: Any]] = []
            for obs in observations {
                var joints: [String: Any] = [:]
                if let points = try? obs.recognizedPoints(.all) {
                    for (jointKey, point) in points {
                        guard point.confidence > 0.1 else { continue }
                        let yFlipped = 1.0 - point.location.y
                        joints[jointName(jointKey)] = [
                            "x":          point.location.x,
                            "y":          yFlipped,
                            "confidence": Double(point.confidence)
                        ]
                    }
                }
                bodies.append([
                    "joints":     joints,
                    "confidence": Double(obs.confidence)
                ])
            }
            DispatchQueue.main.async {
                completion(["bodies": bodies])
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

    /// VNHumanBodyPoseObservation.JointName.rawValue is something like
    /// "head_joint" or "left_shoulder_1_joint" — verbose and version-shifty.
    /// Normalize to camelCase keys the JS side can read directly.
    private static func jointName(_ key: VNHumanBodyPoseObservation.JointName) -> String {
        switch key {
        case .nose:          return "nose"
        case .leftEye:       return "leftEye"
        case .rightEye:      return "rightEye"
        case .leftEar:       return "leftEar"
        case .rightEar:      return "rightEar"
        case .leftShoulder:  return "leftShoulder"
        case .rightShoulder: return "rightShoulder"
        case .neck:          return "neck"
        case .leftElbow:     return "leftElbow"
        case .rightElbow:    return "rightElbow"
        case .leftWrist:     return "leftWrist"
        case .rightWrist:    return "rightWrist"
        case .leftHip:       return "leftHip"
        case .rightHip:      return "rightHip"
        case .root:          return "root"
        case .leftKnee:      return "leftKnee"
        case .rightKnee:     return "rightKnee"
        case .leftAnkle:     return "leftAnkle"
        case .rightAnkle:    return "rightAnkle"
        // Fallback for any joint Apple adds in future macOS versions. We
        // emit String(describing:) rather than rawValue because the
        // VNRecognizedPointKey rawValue type is SDK-version-shifty.
        default:             return String(describing: key)
        }
    }
}
