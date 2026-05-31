import Foundation
import Vision
import AppKit
import CoreImage

// VNGenerateForegroundInstanceMaskRequest (macOS 14+) — Apple's "lift
// subject from background" engine, the same one Photos.app uses for
// long-press subject extraction. Returns the masked image as a PNG dataURL
// with the subject on transparent background, ready to drop into an <img>
// or composite over anything.
//
// Older macOS gracefully returns nil — stacks should treat absence as a
// capability gap, not an error.
//
// Consumers — webcam green-screen replacement ("replace my background with
// today's wallpaper"), recipe scanner ("lift the dish out of the photo for
// my UI"), screenshot cleanup ("just the window, no desktop"). Pairs with
// sd.display.snapshot today and a future sd.camera.frame() for live use.

extension Vision {
    /// image: dataURL or absolute path. Returns
    ///   { dataURL: "data:image/png;base64,...", width, height }
    /// where the image is the original masked to its foreground instances.
    /// Returns nil on older macOS (< 14), failed decode, or no detected
    /// subject.
    static func subjectMask(image source: Any?,
                            completion: @escaping ([String: Any]?) -> Void) {
        guard #available(macOS 14.0, *) else {
            completion(nil); return
        }
        guard let cgImage = decodeImage(source) else {
            completion(nil); return
        }

        let request = VNGenerateForegroundInstanceMaskRequest { request, _ in
            guard let observation = (request.results as? [VNInstanceMaskObservation])?.first else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                let buffer = try observation.generateMaskedImage(
                    ofInstances: observation.allInstances,
                    from: handler,
                    croppedToInstancesExtent: false
                )
                guard let png = pngDataURL(from: buffer) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                DispatchQueue.main.async { completion(png) }
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

    /// CVPixelBuffer (RGBA, premultiplied) → PNG dataURL via CoreImage +
    /// CGImageDestination. CIContext is cheap to construct here (per call)
    /// since the request itself is already an expensive ML hop; if a hot
    /// path emerges, hoist into a static `let ciContext` next to this.
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
}
