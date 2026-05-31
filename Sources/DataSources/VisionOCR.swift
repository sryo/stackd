import Foundation
import Vision
import AppKit

// Apple's Vision framework — OCR via VNRecognizeTextRequest.
// Sibling of NLP.swift in shape: fire-and-forget request, returns a flat
// array of observations the JS caller can render.
//
// VNRecognizeTextRequest defaults to .accurate; .fast is ~5x quicker but
// drops detail on small text. boundingBox values arrive in Vision's
// normalized origin-bottom-left coordinate space; we flip y so JS-side
// rendering on top of an <img> just works.
//
// Consumer notes — DigUp (primary): "screenshot-every-N-seconds, OCR,
// fulltext index" use case where the OCR overhead is the bottleneck and the
// raw observation list is what gets stuffed into the FTS index. Secondary:
// "extract text from a screenshot" stack — drop an image on it, get
// selectable text back, copy to clipboard.

enum Vision {
    /// image: either a base64 dataURL ("data:image/png;base64,...") or an
    /// absolute path. languages: BCP-47 codes Vision recognizes; empty falls
    /// back to its automatic-language detection. level: "fast" | "accurate".
    static func ocr(image source: Any?,
                    languages: [String]?,
                    level: String,
                    completion: @escaping ([String: Any]?) -> Void) {
        guard let cgImage = decodeImage(source) else {
            completion(nil); return
        }

        let request = VNRecognizeTextRequest { request, _ in
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            var out: [[String: Any]] = []
            for obs in observations {
                guard let top = obs.topCandidates(1).first else { continue }
                // VNRecognizedTextObservation.boundingBox is Vision-normalized
                // (origin bottom-left). Flip y to top-left for the standard
                // web rendering coordinate space.
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
            DispatchQueue.main.async {
                completion(["observations": out])
            }
        }
        if let langs = languages, !langs.isEmpty {
            request.recognitionLanguages = langs
        }
        request.recognitionLevel = (level == "fast") ? .fast : .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// Accepts dataURL strings or filesystem paths. Returns a CGImage either way.
    /// Module-internal so sibling Vision request types (VisionFaces.swift,
    /// VisionFeaturePrint.swift, VisionSubjectMask.swift, …) share the same
    /// image-decoding contract — every Vision.* method takes the same `image:`
    /// shape (dataURL or absolute path).
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
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // PNG vs JPEG — let CGImageSource sniff the bytes rather than parsing
        // the URL header. Cheaper and correct for both formats SCStream emits.
        guard let source = CGImageSourceCreateWithDataProvider(provider, nil) else { return nil }
        _ = source
        guard let cgSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(cgSource, 0, nil)
    }
}
