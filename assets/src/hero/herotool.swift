// Tiny helper for record.sh — compiled on the fly with swiftc.
//
//   herotool geometry            → JSON with the primary display's frame,
//                                  visibleFrame, scale and the centered
//                                  1200×676 capture rect (top-left coords)
//   herotool warp <x> <y>        → move the cursor (top-left coords, no click)
//   herotool windows <pid>       → JSON list of on-screen windows owned by pid
//                                  (bounds in top-left coords, alpha, layer)

import AppKit
import CoreGraphics
import Foundation

let captureW = 1200.0
let captureH = 676.0

func geometry() -> [String: Any] {
    guard let screen = NSScreen.screens.first else {
        FileHandle.standardError.write(Data("herotool: no screens\n".utf8)); exit(2)
    }
    let f = screen.frame
    let vf = screen.visibleFrame
    let menubarH = f.maxY - vf.maxY
    let cx = floor((f.width - captureW) / 2)
    let cy = floor((f.height - captureH) / 2)
    return [
        "screenW": f.width, "screenH": f.height,
        "scale": screen.backingScaleFactor,
        // visibleFrame in top-left coordinates
        "vfX": vf.minX, "vfTop": f.maxY - vf.maxY, "vfW": vf.width, "vfH": vf.height,
        "menubarH": menubarH,
        "captureX": cx, "captureY": cy, "captureW": captureW, "captureH": captureH,
    ]
}

func windows(pid: Int32) -> [[String: Any]] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid else { return nil }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return [
            "id": w[kCGWindowNumber as String] ?? 0,
            "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
            "alpha": w[kCGWindowAlpha as String] ?? 1,
            "layer": w[kCGWindowLayer as String] ?? 0,
        ]
    }
}

func emit(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "geometry":
    emit(geometry())
case "warp":
    let a = Array(args)
    guard a.count == 3, let x = Double(a[1]), let y = Double(a[2]) else {
        FileHandle.standardError.write(Data("usage: herotool warp <x> <y>\n".utf8)); exit(64)
    }
    let err = CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    exit(err == .success ? 0 : 1)
case "windows":
    let a = Array(args)
    guard a.count == 2, let pid = Int32(a[1]) else {
        FileHandle.standardError.write(Data("usage: herotool windows <pid>\n".utf8)); exit(64)
    }
    emit(windows(pid: pid))
default:
    FileHandle.standardError.write(Data("usage: herotool geometry | warp <x> <y> | windows <pid>\n".utf8))
    exit(64)
}
