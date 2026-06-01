import Foundation
import Vision
import AppKit
import CoreImage

// Apple's Vision framework — one file, five public entrypoints.
// Each Vision.* entrypoint takes the same `image:` shape (a base64 dataURL or
// an absolute filesystem path) so stacks can pipe sd.display.snapshot or a
// future sd.camera.frame() straight in. Decoding, the background dispatch,
// and the try/catch around `handler.perform([...])` are shared via
// `runRequest(...)`; each public method below is responsible only for
// constructing its VNRequest and shaping the results dict for the JS caller.
//
// Bounding boxes / point coordinates leave this file in web-style top-left
// normalized space (0..1, y already flipped from Vision's bottom-left origin).
// That contract is invariant across ocr / faces / bodyPose — stacks can mix
// outputs without re-normalizing.

enum Vision {

    // MARK: - Public entrypoints

    /// OCR via VNRecognizeTextRequest. languages: BCP-47 codes, empty falls
    /// back to Vision's automatic detection. level: "fast" | "accurate".
    /// .fast is ~5x quicker but drops detail on small text.
    /// Primary consumer: DigUp ("screenshot every N seconds, OCR, FTS index").
    static func ocr(image source: Any?,
                    languages: [String]?,
                    level: String,
                    completion: @escaping ([String: Any]?) -> Void) {
        runRequest(image: source, completion: completion) {
            let request = VNRecognizeTextRequest()
            if let langs = languages, !langs.isEmpty {
                request.recognitionLanguages = langs
            }
            request.recognitionLevel = (level == "fast") ? .fast : .accurate
            request.usesLanguageCorrection = true
            return request
        } decode: { (request: VNRecognizeTextRequest, _) in
            let observations = request.results ?? []
            var out: [[String: Any]] = []
            for obs in observations {
                guard let top = obs.topCandidates(1).first else { continue }
                let bb = obs.boundingBox
                let yFlipped = 1.0 - bb.origin.y - bb.size.height
                out.append([
                    "text":       top.string,
                    "confidence": Double(top.confidence),
                    "boundingBox": [
                        "x": bb.origin.x,
                        "y": yFlipped,
                        "w": bb.size.width,
                        "h": bb.size.height
                    ]
                ])
            }
            return ["observations": out]
        }
    }

    /// Face rectangles + head-pose angles (roll/yaw/pitch when Vision is
    /// confident). NO identity, NO recognition, NO landmarks — separate
    /// request types with stricter privacy bargains.
    /// Consumers: webcam green-screen, "blur all faces before sharing."
    static func faces(image source: Any?,
                      completion: @escaping ([String: Any]?) -> Void) {
        runRequest(image: source, completion: completion) {
            VNDetectFaceRectanglesRequest()
        } decode: { (request: VNDetectFaceRectanglesRequest, _) in
            let observations = request.results ?? []
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
            return ["observations": out]
        }
    }

    /// Vision's perceptual hash. Returns a base64 NSKeyedArchiver blob of the
    /// full VNFeaturePrintObservation — JS stashes it and later hands two
    /// blobs back to `featurePrintDistance` to compare. We archive the whole
    /// observation (not just .data) because the raw float buffer alone isn't
    /// reconstructible into a VNFeaturePrintObservation through any public
    /// initializer.
    /// Consumers: DigUp near-dup detector, "user left the desk" webcam idle.
    static func featurePrint(image source: Any?,
                             completion: @escaping ([String: Any]?) -> Void) {
        runRequest(image: source, completion: completion) {
            VNGenerateImageFeaturePrintRequest()
        } decode: { (request: VNGenerateImageFeaturePrintRequest, _) in
            guard let observation = request.results?.first else {
                return nil
            }
            guard let archived = try? NSKeyedArchiver.archivedData(
                withRootObject: observation,
                requiringSecureCoding: true
            ) else { return nil }
            return [
                "print":        archived.base64EncodedString(),
                "elementCount": observation.elementCount,
                "elementType":  elementTypeName(observation.elementType)
            ]
        }
    }

    /// Compare two feature prints (both base64 NSKeyedArchiver blobs from
    /// `featurePrint`). Returns `{ distance: Double }` — lower means more
    /// similar; identical images return ~0. Returns nil if either blob fails
    /// to unarchive or the two prints aren't comparable (different element
    /// type/count — Vision raises on mismatch).
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

    /// "Lift subject from background" — Photos.app's long-press extractor.
    /// Returns the masked image as a PNG dataURL with the subject on
    /// transparent background. Returns nil on older macOS (< 14), failed
    /// decode, or no detected subject.
    /// Consumers: webcam green-screen, screenshot cleanup ("just the window").
    static func subjectMask(image source: Any?,
                            completion: @escaping ([String: Any]?) -> Void) {
        guard #available(macOS 14.0, *) else {
            completion(nil); return
        }
        runRequest(image: source, completion: completion) {
            VNGenerateForegroundInstanceMaskRequest()
        } decode: { (request: VNGenerateForegroundInstanceMaskRequest, cgImage) in
            guard let observation = request.results?.first else {
                return nil
            }
            // Need a fresh handler bound to the same source image — the one
            // that ran the request isn't exposed back out of runRequest, and
            // generateMaskedImage needs *a* handler over the same pixels.
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard let buffer = try? observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            ) else { return nil }
            return pngDataURL(from: buffer)
        }
    }

    /// 2D joint keypoints per detected body (up to 17 named joints each).
    /// Joint coordinates are web-style top-left origin in 0..1. A joint is
    /// omitted from the dict if Vision's per-joint confidence is below 0.1 —
    /// under that threshold the position is effectively noise.
    /// Consumers: posture coaching, gesture UIs, motion-capture overlays.
    static func bodyPose(image source: Any?,
                         completion: @escaping ([String: Any]?) -> Void) {
        runRequest(image: source, completion: completion) {
            VNDetectHumanBodyPoseRequest()
        } decode: { (request: VNDetectHumanBodyPoseRequest, _) in
            let observations = request.results ?? []
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
            return ["bodies": bodies]
        }
    }

    // MARK: - Shared plumbing

    /// Background-dispatch + image-decode + try/catch shared by every
    /// Vision.* entrypoint above. The caller supplies a `build` closure that
    /// returns its specific VNRequest subclass, and a `decode` closure that
    /// turns the completed request (and the source CGImage, for subjectMask)
    /// into a results dict. `decode` returning nil collapses to
    /// `completion(nil)` — same shape callers had before the merge.
    ///
    /// Generic over `R: VNRequest` so each call site keeps its concrete
    /// request type without casting; the request is held strongly inside
    /// `perform([request])` for its lifetime.
    private static func runRequest<R: VNRequest>(
        image source: Any?,
        completion: @escaping ([String: Any]?) -> Void,
        build: @escaping () -> R,
        decode: @escaping (R, CGImage) -> [String: Any]?
    ) {
        guard let cgImage = decodeImage(source) else {
            completion(nil); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = build()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let payload = decode(request, cgImage)
                DispatchQueue.main.async { completion(payload) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// Accepts dataURL strings or filesystem paths. Returns a CGImage either
    /// way. Every Vision.* method takes this same `image:` shape so stacks
    /// can pipe one source through any request type without reshaping.
    static func decodeImage(_ source: Any?) -> CGImage? {
        if let s = source as? String {
            if s.hasPrefix("data:") {
                return decodeDataURL(s)
            }
            let expanded = (s as NSString).expandingTildeInPath
            if let img = NSImage(contentsOfFile: expanded) {
                var rect = NSRect(origin: .zero, size: img.size)
                return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
        }
        return nil
    }

    private static func decodeDataURL(_ s: String) -> CGImage? {
        // Expected shape: data:<mime>;base64,<payload>
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let payload = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        // PNG vs JPEG — let CGImageSource sniff the bytes rather than parsing
        // the URL header. Cheaper and correct for both formats SCStream emits.
        guard let cgSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(cgSource, 0, nil)
    }

    // MARK: - Per-request decoder helpers

    /// CVPixelBuffer (RGBA, premultiplied) → PNG dataURL via CoreImage +
    /// CGImageDestination. CIContext is cheap to construct here (per call)
    /// since the request itself is already an expensive ML hop; if a hot path
    /// emerges, hoist into a `static let ciContext` next to this.
    private static func pngDataURL(from buffer: CVPixelBuffer) -> [String: Any]? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let base64 = (data as Data).base64EncodedString()
        return [
            "dataURL": "data:image/png;base64,\(base64)",
            "width":   cgImage.width,
            "height":  cgImage.height
        ]
    }

    private static func elementTypeName(_ t: VNElementType) -> String {
        switch t {
        case .float:   return "float"
        case .double:  return "double"
        default:       return "unknown"
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
        // Fallback for any joint Apple adds in future macOS versions. We emit
        // String(describing:) rather than rawValue because the
        // VNRecognizedPointKey rawValue type is SDK-version-shifty.
        default:             return String(describing: key)
        }
    }
}
