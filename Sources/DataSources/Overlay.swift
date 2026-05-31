import AppKit
import CoreGraphics

// JankyBorders-style overlay: a SkyLight-owned sibling window pinned to a
// target window (one we don't own), drawn into via a CGContext sourced
// from SLWindowContextCreate. Lets stacks render focused-window accent
// borders, debug highlights, or pixel-accurate annotations without
// spawning an NSWindow per overlay.
//
// Why "sibling window" instead of literally writing into the target's
// surface: the target window's IOSurface belongs to the owning process;
// our connection has no draw access. JankyBorders sidesteps this by
// creating its OWN window (via SLSNewWindow on our own cid) and gluing it
// to the target's geometry / z-order / space via SLS transactions. From
// the stack author's perspective it still feels like "draw onto that
// other window" — the implementation just hides the sibling.
//
// Reference: github.com/FelixKratz/JankyBorders/blob/main/src/border.c
//   border_create_window  → window_create + SLWindowContextCreate
//   border_update_internal → SLSDisableUpdate / SLSSetWindowShape /
//                            SLSTransactionMoveWindowWithGroup /
//                            SLSTransactionOrderWindow / SLSReenableUpdate
//
// Per-frame flow (driven by DisplayLink in Bridge):
//   1. SLSGetWindowBounds(target) → target frame
//   2. JS draw(geometry) returns a declarative spec ({ rects, lines, circles })
//   3. If frame changed: SLSDisableUpdate; SLSSetWindowShape; reorder via
//      SLSTransaction; SLSReenableUpdate
//   4. context.clear → translate spec ops to CGContext calls
//   5. SLSFlushWindowContentRegion to commit pixels to the compositor

// CGSRegion is an opaque CF type. Its concrete layout isn't documented and
// CFRelease is the only sanctioned teardown. UnsafeMutableRawPointer matches
// the void* SLS APIs take/return.
typealias CGSRegionRef = UnsafeMutableRawPointer

private enum SkyLightOverlay {
    // CGContextRef-returning factory: binds a fresh CGContext to the back
    // store of `wid`. The wid must be one WE created via SLSNewWindow on the
    // shared cid; you cannot get a context for a foreign-process window
    // (the IOSurface lives in their address space).
    typealias WindowContextCreateFn = @convention(c) (Int32, UInt32, CFDictionary?) -> Unmanaged<CGContext>?

    // Commit pending draws to the compositor. `dirty` of NULL flushes the
    // entire window — sufficient for our spec-driven full-redraw model.
    typealias FlushWindowContentRegionFn = @convention(c) (Int32, UInt32, CGSRegionRef?) -> Int32

    // Resize the window's shape. JankyBorders uses this to grow/shrink the
    // overlay window when the target moves or resizes. Offsets are passed
    // separately so the region itself can stay anchored at (0,0).
    typealias SetWindowShapeFn = @convention(c) (Int32, UInt32, Float, Float, CGSRegionRef?) -> Int32

    // Begin / end an atomic batch of geometry updates. Without these, a
    // resize + move + reorder triple flashes through three intermediate
    // states; bracketed, they commit as one.
    typealias DisableUpdateFn  = @convention(c) (Int32) -> Int32
    typealias ReenableUpdateFn = @convention(c) (Int32) -> Int32

    // bool* out-param. macOS exposes no documented Swift Bool layout for
    // this — CBool / DarwinBoolean both bridge correctly in practice but
    // DarwinBoolean is what AX uses everywhere else in this codebase.
    typealias WindowIsOrderedInFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<DarwinBoolean>) -> Int32

    // Target window bounds in screen-points (top-left origin). The same
    // signal AX returns for focused windows, but available for any wid.
    typealias GetWindowBoundsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

    // Create / release the overlay's own backing window. wid is OUT.
    // type is the CG backing-store hint (kCGBackingStoreBuffered = 2).
    typealias NewWindowFn      = @convention(c) (Int32, Int32, Float, Float, CGSRegionRef?, UnsafeMutablePointer<UInt32>) -> Int32
    typealias ReleaseWindowFn  = @convention(c) (Int32, UInt32) -> Int32

    // Make the overlay window 100% see-through except where we draw. Without
    // this the SLSNewWindow surface is opaque black and the user sees a
    // rectangle of nothing behind the rendered border.
    typealias SetWindowOpacityFn = @convention(c) (Int32, UInt32, Bool) -> Int32

    // Backing-store density. Retina displays need 2.0 or the surface gets
    // bilinearly stretched and a 2pt border draws as 4-5 fuzzy pixels.
    typealias SetWindowResolutionFn = @convention(c) (Int32, UInt32, Double) -> Int32

    // Per-window event mask. NSWindow installs a default mask that lets
    // mouseDown/Up/Moved through; raw SLS windows created via SLSNewWindow
    // also accept events by default on modern macOS — without resetting the
    // mask to 0, the overlay sits above the target and eats every click
    // landing in its (target + 32pt padding) rect. JankyBorders / SketchyBar
    // both call this with mask=0 immediately after window creation.
    typealias SetWindowEventMaskFn = @convention(c) (Int32, UInt32, UInt32) -> Int32

    // SLSTransaction* — atomic move/level/order in one server commit.
    typealias TransactionCreateFn          = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias TransactionCommitFn          = @convention(c) (CFTypeRef, Int32) -> Int32
    typealias TransactionMoveFn            = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Int32
    typealias TransactionOrderWindowFn     = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Int32
    typealias TransactionSetWindowLevelFn  = @convention(c) (CFTypeRef, UInt32, Int32) -> Int32

    // Geometry primitive used by SLSSetWindowShape. The yabai/JankyBorders
    // call site builds a region whose extent is `frame` (origin treated as
    // size offset from the shape origin separately).
    typealias NewRegionWithRectFn = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<CGSRegionRef?>) -> Int32

    static let windowContextCreate:      WindowContextCreateFn?      = SkyLight.sym("SLWindowContextCreate")
    static let flushWindowContentRegion: FlushWindowContentRegionFn? = SkyLight.sym("SLSFlushWindowContentRegion")
    static let setWindowShape:           SetWindowShapeFn?           = SkyLight.sym("SLSSetWindowShape")
    static let disableUpdate:            DisableUpdateFn?            = SkyLight.sym("SLSDisableUpdate")
    static let reenableUpdate:           ReenableUpdateFn?           = SkyLight.sym("SLSReenableUpdate")
    static let windowIsOrderedIn:        WindowIsOrderedInFn?        = SkyLight.sym("SLSWindowIsOrderedIn")
    static let getWindowBounds:          GetWindowBoundsFn?          = SkyLight.sym("SLSGetWindowBounds")
    static let newWindow:                NewWindowFn?                = SkyLight.sym("SLSNewWindow")
    static let releaseWindow:            ReleaseWindowFn?            = SkyLight.sym("SLSReleaseWindow")
    static let setWindowOpacity:         SetWindowOpacityFn?         = SkyLight.sym("SLSSetWindowOpacity")
    static let setWindowResolution:      SetWindowResolutionFn?      = SkyLight.sym("SLSSetWindowResolution")
    static let setWindowEventMask:       SetWindowEventMaskFn?       = SkyLight.sym("SLSSetWindowEventMask")
    static let transactionCreate:        TransactionCreateFn?        = SkyLight.sym("SLSTransactionCreate")
    static let transactionCommit:        TransactionCommitFn?        = SkyLight.sym("SLSTransactionCommit")
    static let transactionMove:          TransactionMoveFn?          = SkyLight.sym("SLSTransactionMoveWindowWithGroup")
    static let transactionOrderWindow:   TransactionOrderWindowFn?   = SkyLight.sym("SLSTransactionOrderWindow")
    static let transactionSetLevel:      TransactionSetWindowLevelFn? = SkyLight.sym("SLSTransactionSetWindowLevel")
    static let newRegionWithRect:        NewRegionWithRectFn?        = SkyLight.sym("CGSNewRegionWithRect")
}

// MARK: - OverlayHandle

/// Live overlay anchored to a target window. Each handle owns:
///   - one SLS overlay window (`overlayWID`) created on our cid
///   - one CGContext bound to that window's back-store
///   - cached last-applied frame (so we only call SetWindowShape on change)
final class OverlayHandle {
    let id: Int
    let targetWID: CGWindowID
    let overlayWID: UInt32
    private let context: CGContext

    // Last frame we positioned the overlay at (in screen-points, top-left
    // origin). Compared against the freshly-fetched bounds on every tick
    // to decide whether to re-shape + re-order — both are server round-trips
    // and JankyBorders skips them when the geometry hasn't changed.
    private var lastFrame: CGRect = .zero

    // Padding around the target frame: the overlay window extends past the
    // target's bounds by this much so strokes drawn at the edge aren't
    // clipped. Borders are typically 1-2px so 16px is plenty of headroom.
    static let padding: CGFloat = 16

    init(id: Int, targetWID: CGWindowID, overlayWID: UInt32, context: CGContext) {
        self.id = id
        self.targetWID = targetWID
        self.overlayWID = overlayWID
        self.context = context
    }

    /// Per-tick redraw. `targetFrame` is the current SLSGetWindowBounds of
    /// the target window (screen-points, top-left origin). `spec` is the
    /// declarative draw dict returned by the stack's JS callback.
    ///
    /// Coordinate convention: the spec's (0,0) is the top-left of the
    /// target window. The overlay window is sized `target + 2*padding` and
    /// positioned `padding` up-left of the target, so the spec's (0,0) maps
    /// to (padding, padding) inside the overlay's local coord space.
    func draw(spec: [String: Any], targetFrame: CGRect) {
        let cid = SkyLight.cid

        let pad = OverlayHandle.padding
        let overlayFrame = CGRect(
            x: targetFrame.origin.x - pad,
            y: targetFrame.origin.y - pad,
            width:  targetFrame.size.width + 2 * pad,
            height: targetFrame.size.height + 2 * pad
        )

        _ = SkyLightOverlay.disableUpdate?(cid)

        // Reposition / resize only when the target moved/resized. JankyBorders
        // bails out of the shape+transaction path on equal frames; the
        // CGContext is sticky across moves (it follows the window).
        if !rectsApproxEqual(overlayFrame, lastFrame) {
            applyGeometry(overlayFrame: overlayFrame)
            lastFrame = overlayFrame
        }

        // Always clear + redraw. The spec is the source of truth for the
        // frame's contents; if the stack wants to skip a frame it returns
        // an empty spec ({}) and we still clear (so a stale stroke from a
        // previous tick doesn't ghost).
        let doClear = (spec["clear"] as? Bool) ?? true
        if doClear {
            context.clear(CGRect(origin: .zero, size: overlayFrame.size))
        }

        // Pen origin: translate so (0,0) in spec coords is the top-left of
        // the TARGET (not the overlay). Spec authors should never need to
        // know about the padding band.
        context.saveGState()
        // SLWindowContextCreate's CGContext uses bottom-left origin (CG
        // default). Flip Y so spec authors can write top-left coordinates,
        // matching every other surface in stackd (CSS, AX positions,
        // CGWindowBounds, etc.). After this flip: spec (0,0) is the
        // top-left corner of the target window's box.
        context.translateBy(x: pad, y: overlayFrame.size.height - pad)
        context.scaleBy(x: 1, y: -1)

        if let rects = spec["rects"] as? [[String: Any]] {
            for r in rects { drawRect(r) }
        }
        if let lines = spec["lines"] as? [[String: Any]] {
            for l in lines { drawLine(l) }
        }
        if let circles = spec["circles"] as? [[String: Any]] {
            for c in circles { drawCircle(c) }
        }

        context.restoreGState()
        context.flush()

        // NULL region = flush the whole window. We always full-redraw so
        // tracking a dirty rect would just be bookkeeping.
        _ = SkyLightOverlay.flushWindowContentRegion?(cid, overlayWID, nil)

        _ = SkyLightOverlay.reenableUpdate?(cid)
    }

    /// Tear down. Releases the SLS window (which kills the back-store and
    /// invalidates our CGContext — CG ARC then drops the context ref).
    func detach() {
        let cid = SkyLight.cid
        _ = SkyLightOverlay.releaseWindow?(cid, overlayWID)
    }

    deinit {
        // Last-resort cleanup if detach() wasn't called explicitly. The Bridge
        // detach path is the normal route; this catches scope-drain edge cases
        // where the handle dict is cleared without an explicit detach.
        let cid = SkyLight.cid
        _ = SkyLightOverlay.releaseWindow?(cid, overlayWID)
    }

    // MARK: - Geometry

    private func applyGeometry(overlayFrame: CGRect) {
        let cid = SkyLight.cid

        // Re-shape the overlay to the new size. The shape is what defines
        // the window's pixel extent on the compositor; SetWindowShape
        // accepts an offset for the origin and a region for the size.
        // JankyBorders passes the FULL rect into CGSNewRegionWithRect then
        // moves the origin separately — we do the same.
        var sizedRect = CGRect(origin: .zero, size: overlayFrame.size)
        var region: CGSRegionRef? = nil
        if let mk = SkyLightOverlay.newRegionWithRect {
            _ = mk(&sizedRect, &region)
        }
        if let region = region {
            _ = SkyLightOverlay.setWindowShape?(cid, overlayWID,
                                                Float(overlayFrame.origin.x),
                                                Float(overlayFrame.origin.y),
                                                region)
            // Region is a CF type — release via Unmanaged so we don't leak.
            Unmanaged<CFTypeRef>.fromOpaque(region).release()
        }

        // Atomically move + order above the target. JankyBorders uses
        // SLSTransactionMoveWindowWithGroup (not SLSMoveWindow) to keep the
        // overlay snapped to the target through live drags. Order = 1
        // (above target) with reference wid = targetWID.
        guard let txCreate  = SkyLightOverlay.transactionCreate,
              let txMove    = SkyLightOverlay.transactionMove,
              let txOrder   = SkyLightOverlay.transactionOrderWindow,
              let txCommit  = SkyLightOverlay.transactionCommit else { return }
        guard let txRef = txCreate(cid)?.takeRetainedValue() else { return }
        _ = txMove(txRef, overlayWID, overlayFrame.origin)
        _ = txOrder(txRef, overlayWID, 1, targetWID)
        _ = txCommit(txRef, 0)
    }

    private func rectsApproxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        // Sub-pixel jitter from AX/CG round-trips would otherwise force a
        // shape rebuild every tick. 0.5pt is well under "user notices".
        abs(a.origin.x - b.origin.x) < 0.5 &&
        abs(a.origin.y - b.origin.y) < 0.5 &&
        abs(a.size.width  - b.size.width)  < 0.5 &&
        abs(a.size.height - b.size.height) < 0.5
    }

    // MARK: - Spec → CGContext

    private func drawRect(_ r: [String: Any]) {
        guard let x = num(r["x"]), let y = num(r["y"]),
              let w = num(r["w"]), let h = num(r["h"]),
              w > 0, h > 0 else { return }
        let radius = num(r["radius"]) ?? 0
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path: CGPath
        if radius > 0 {
            // Clamp radius to half the shorter side so the geometry stays
            // valid (CGPath asserts otherwise on extreme cases).
            let cap = min(radius, min(w, h) / 2)
            path = CGPath(roundedRect: rect, cornerWidth: cap, cornerHeight: cap, transform: nil)
        } else {
            path = CGPath(rect: rect, transform: nil)
        }
        context.addPath(path)
        if let fill = color(r["fill"]) {
            context.setFillColor(fill)
            context.fillPath()
            context.addPath(path) // fill consumed the path; re-add for stroke
        }
        if let stroke = color(r["stroke"]) {
            let width = num(r["strokeWidth"]) ?? 1
            context.setStrokeColor(stroke)
            context.setLineWidth(width)
            context.strokePath()
        } else {
            // No stroke — drop any path we left dangling so the next
            // primitive starts clean.
            context.beginPath()
        }
    }

    private func drawLine(_ l: [String: Any]) {
        guard let x1 = num(l["x1"]), let y1 = num(l["y1"]),
              let x2 = num(l["x2"]), let y2 = num(l["y2"]),
              let stroke = color(l["stroke"]) else { return }
        let width = num(l["width"]) ?? 1
        context.setStrokeColor(stroke)
        context.setLineWidth(width)
        context.beginPath()
        context.move(to: CGPoint(x: x1, y: y1))
        context.addLine(to: CGPoint(x: x2, y: y2))
        context.strokePath()
    }

    private func drawCircle(_ c: [String: Any]) {
        guard let cx = num(c["cx"]), let cy = num(c["cy"]),
              let r = num(c["r"]), r > 0 else { return }
        let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
        context.addEllipse(in: rect)
        if let fill = color(c["fill"]) {
            context.setFillColor(fill)
            context.fillPath()
            context.addEllipse(in: rect)
        }
        if let stroke = color(c["stroke"]) {
            let width = num(c["strokeWidth"]) ?? 1
            context.setStrokeColor(stroke)
            context.setLineWidth(width)
            context.strokePath()
        } else {
            context.beginPath()
        }
    }

    private func num(_ v: Any?) -> CGFloat? {
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int    { return CGFloat(i) }
        if let n = v as? NSNumber { return CGFloat(truncating: n) }
        return nil
    }

    // "#RGB" / "#RRGGBB" / "#RRGGBBAA" → CGColor. Returns nil for any
    // unparseable input (including non-strings) so the call site can skip
    // the relevant draw step entirely instead of falling back to a
    // surprise default color.
    private func color(_ v: Any?) -> CGColor? {
        guard let s = v as? String, s.hasPrefix("#") else { return nil }
        let hex = String(s.dropFirst())
        var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 255
        switch hex.count {
        case 3:
            // #RGB shorthand → expand each nibble. Standard CSS rule.
            let chars = Array(hex)
            r = (parseHex("\(chars[0])\(chars[0])") ?? 0)
            g = (parseHex("\(chars[1])\(chars[1])") ?? 0)
            b = (parseHex("\(chars[2])\(chars[2])") ?? 0)
        case 6:
            guard let v = parseHex(hex) else { return nil }
            r = (v >> 16) & 0xFF
            g = (v >> 8) & 0xFF
            b = v & 0xFF
        case 8:
            guard let v = parseHex(hex) else { return nil }
            r = (v >> 24) & 0xFF
            g = (v >> 16) & 0xFF
            b = (v >> 8) & 0xFF
            a = v & 0xFF
        default:
            return nil
        }
        return CGColor(srgbRed: CGFloat(r) / 255.0,
                       green:   CGFloat(g) / 255.0,
                       blue:    CGFloat(b) / 255.0,
                       alpha:   CGFloat(a) / 255.0)
    }

    private func parseHex(_ s: String) -> UInt32? {
        UInt32(s, radix: 16)
    }
}

// MARK: - Overlay (factory)

enum Overlay {
    /// Allocate a new SLS overlay window pinned to `targetID`. Returns nil if
    /// the SkyLight symbols couldn't be loaded, the region build failed, or
    /// SLSNewWindow refused the request. The handle owns the overlay window
    /// — call `detach()` to release it.
    static func attach(targetID: CGWindowID, id: Int) -> OverlayHandle? {
        let cid = SkyLight.cid
        guard cid != 0 else { return nil }
        guard let newWindow      = SkyLightOverlay.newWindow,
              let makeContext    = SkyLightOverlay.windowContextCreate,
              let newRegion      = SkyLightOverlay.newRegionWithRect,
              let setOpacity     = SkyLightOverlay.setWindowOpacity else {
            return nil
        }

        // Initial frame: 1x1 offscreen. The first draw() call will reshape
        // and reposition to fit the target's current bounds. We can't size
        // the window correctly here because SLSGetWindowBounds may not be
        // resolvable yet (the target may have just spawned). The offscreen
        // placement keeps the empty overlay invisible until the first tick.
        var initialRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var region: CGSRegionRef? = nil
        guard newRegion(&initialRect, &region) == 0, let region = region else {
            return nil
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(region).release() }

        var overlayWID: UInt32 = 0
        // type=2 = kCGBackingStoreBuffered. x/y are -9999 to keep the empty
        // window offscreen until the first draw() reshapes it; JankyBorders
        // uses the same trick to dodge a one-frame flash at the screen origin.
        let newErr = newWindow(cid, 2, -9999, -9999, region, &overlayWID)
        guard newErr == 0, overlayWID != 0 else { return nil }

        // Transparent window: only our drawn pixels show. Without this the
        // overlay paints opaque black over the target window — the exact
        // bug JankyBorders fixes by calling SLSSetWindowOpacity(false).
        _ = setOpacity(cid, overlayWID, false)

        // Make the overlay click-through. The SLSNewWindow default lets mouse
        // events land here, so the overlay would intercept every click in its
        // (target + 32pt padding) rect — the user sees the target window
        // refusing to respond to clicks. Mask 0 = no event types received,
        // so clicks fall through to the next window down (the actual target).
        _ = SkyLightOverlay.setWindowEventMask?(cid, overlayWID, 0)

        // HiDPI backing density. 2.0 = Retina. Without this every drawn
        // stroke is bilinearly upscaled and a 2pt border draws as 4-5
        // fuzzy pixels. JankyBorders gates this behind a --hidpi flag; we
        // unconditionally use the max scale of any active display since
        // overlays follow windows across screens and re-creating the
        // backing store on display change is too expensive.
        let scale = NSScreen.screens.map { $0.backingScaleFactor }.max() ?? 1.0
        _ = SkyLightOverlay.setWindowResolution?(cid, overlayWID, Double(scale))

        guard let ctxRef = makeContext(cid, overlayWID, nil) else {
            _ = SkyLightOverlay.releaseWindow?(cid, overlayWID)
            return nil
        }
        let context = ctxRef.takeRetainedValue()
        context.interpolationQuality = .none

        return OverlayHandle(
            id: id,
            targetWID: targetID,
            overlayWID: overlayWID,
            context: context
        )
    }

    /// Read the current bounds of a window we don't own. Top-left origin,
    /// screen-points. Returns nil if the wid is unknown or SLS rejects it
    /// (which it does silently for windows that died between the JS call
    /// and the next tick — the bridge handles the nil by skipping the draw).
    static func bounds(of wid: CGWindowID) -> CGRect? {
        guard let fn = SkyLightOverlay.getWindowBounds else { return nil }
        var frame = CGRect.zero
        let err = fn(SkyLight.cid, UInt32(wid), &frame)
        return err == 0 ? frame : nil
    }

    /// Is the window currently ordered-in (visible)? Used by the bridge to
    /// suppress draws on minimized / hidden targets without tearing down
    /// the overlay handle.
    static func isOrderedIn(_ wid: CGWindowID) -> Bool {
        guard let fn = SkyLightOverlay.windowIsOrderedIn else { return false }
        var shown: DarwinBoolean = false
        _ = fn(SkyLight.cid, UInt32(wid), &shown)
        return shown.boolValue
    }
}
