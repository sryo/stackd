import Foundation
import Vision

// VNDetectFaceRectanglesRequest — bounding rectangles for every face in the
// image, plus head pose angles (roll/yaw/pitch) when Vision is confident
// enough to report them. NO identity, NO recognition, NO landmarks — those
// are separate request types and stricter privacy bargains.
//
// Consumers — webcam-driven stacks ("highlight my face for green-screen,"
// "auto-frame me in a recording"), screenshot tools ("blur all faces in
// this screenshot before sharing"). Pairs cleanly with sd.display.snapshot
// today and with a future sd.camera.frame() primitive.

extension Vision {
    /// image: dataURL or absolute path (same shape as Vision.ocr). Returns
    ///   { observations: [{ boundingBox: {x,y,w,h}, confidence,
    ///                       roll?, yaw?, pitch? }] }
    /// Bounding box is web-style top-left origin in 0..1 (y-flipped from
    /// Vision's normalized origin-bottom-left). Head-pose angles are in
    /// radians; missing when Vision can't estimate them.
    static func faces(image source: Any?,
                      completion: @escaping ([String: Any]?) -> Void) {
        guard let cgImage = decodeImage(source) else {
            completion(nil); return
        }

        let request = VNDetectFaceRectanglesRequest { request, _ in
            let observations = (request.results as? [VNFaceObservation]) ?? []
            var out: [[String: Any]] = []
            for obs in observations {
                let bb = obs.boundingBox
                let yFlipped = 1.0 - bb.origin.y - bb.size.height
                var entry: [String: Any] = [
                    "confidence": Double(obs.confidence),
                    "boundingBox": [
                        "x": bb.origin.x,
                        "y": yFlipped,
                        "w": bb.size.width,
                        "h": bb.size.height
                    ]
                ]
                if let roll  = obs.roll  { entry["roll"]  = roll.doubleValue }
                if let yaw   = obs.yaw   { entry["yaw"]   = yaw.doubleValue }
                if let pitch = obs.pitch { entry["pitch"] = pitch.doubleValue }
                out.append(entry)
            }
            DispatchQueue.main.async {
                completion(["observations": out])
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
}
