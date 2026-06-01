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

    // SLSReleaseWindow tears down the overlay window's back-store.
    typealias ReleaseWindowFn  = @convention(c) (Int32, UInt32) -> Int32

    // SLSNewWindowWithOpaqueShapeAndContext is the focus-safe path: the
    // window's OPAQUE shape (the region the WindowServer treats as "real
    // pixels that should receive events") is decoupled from its drawing
    // shape. Pass an empty region for the opaque shape and the window
    // never intercepts clicks — they fall through to whatever is below,
    // including the target. SLSSetWindowEventMask(0) alone is not enough:
    // the window can still STEAL FOCUS on click on some macOS versions
    // because the WindowServer's hit-test is based on the opaque shape,
    // not the event mask.
    //   options arg = 13 | (1<<18)  — bit 18 is "ignores cycle" (excludes
    //   from cmd-tab + mission control)
    //   tag_size = 64 (number of bits, NOT bytes)
    typealias NewWindowWithOpaqueShapeFn = @convention(c) (
        Int32,            // cid
        Int32,            // type (kCGBackingStoreBuffered = 2)
        CGSRegionRef?,    // frame region (the drawn extent)
        CGSRegionRef?,    // opaque region (what hit-tests as "the window")
        Int32,            // options (13 | (1<<18) per JankyBorders)
        UnsafeMutablePointer<UInt64>,  // initial tags
        Float,            // x
        Float,            // y
        Int32,            // tag_size (bits)
        UnsafeMutablePointer<UInt32>,  // wid OUT
        UnsafeRawPointer?              // context (NULL)
    ) -> Int32

    // Empty-region factory for the opaque-shape arg. CFRelease to free.
    typealias CreateEmptyRegionFn = @convention(c) () -> CGSRegionRef?

    // Per-pixel-alpha compositing toggle. opacity=false tells the
    // WindowServer to honor the alpha channel of every back-store pixel.
    // Required for the overlay to actually appear transparent where we
    // haven't drawn — without it the empty back-store regions composite
    // as opaque (whatever the format's default fill is).
    typealias SetWindowOpacityFn = @convention(c) (Int32, UInt32, Bool) -> Int32

    // Window tag manipulation. JankyBorders re-asserts the floating /
    // sticky-across-spaces tags after creation (and clears the inverse
    // bits) — without this on some macOS versions the window still
    // surfaces in cmd-tab and Mission Control and CAN STEAL FOCUS on
    // click despite the empty opaque shape, because the WindowServer's
    // focus-routing path uses the tag bitfield separately from hit-test.
    // tag_size is BITS (not bytes); 64 covers all known tag bits.
    typealias SetWindowTagsFn   = @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int32) -> Int32
    typealias ClearWindowTagsFn = @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int32) -> Int32

    // Window-wide alpha (NOT per-pixel). 0 = fully invisible window,
    // 1 = fully visible (final composited alpha = window alpha * pixel
    // alpha). JankyBorders creates with alpha=0 to dodge the first-frame
    // garbage-pixel flash, then bumps to 1 once the back-store is clean.
    typealias SetWindowAlphaFn = @convention(c) (Int32, UInt32, Float) -> Int32

    // Backing-store density. Retina displays need 2.0 or the surface gets
    // bilinearly stretched and a 2pt border draws as 4-5 fuzzy pixels.
    typealias SetWindowResolutionFn = @convention(c) (Int32, UInt32, Double) -> Int32

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
    static let newWindowWithOpaqueShape: NewWindowWithOpaqueShapeFn? = SkyLight.sym("SLSNewWindowWithOpaqueShapeAndContext")
    static let createEmptyRegion:        CreateEmptyRegionFn?        = SkyLight.sym("CGRegionCreateEmptyRegion")
    static let releaseWindow:            ReleaseWindowFn?            = SkyLight.sym("SLSReleaseWindow")
    static let setWindowOpacity:         SetWindowOpacityFn?         = SkyLight.sym("SLSSetWindowOpacity")
    static let setWindowAlpha:           SetWindowAlphaFn?           = SkyLight.sym("SLSSetWindowAlpha")
    static let setWindowTags:            SetWindowTagsFn?            = SkyLight.sym("SLSSetWindowTags")
    static let clearWindowTags:          ClearWindowTagsFn?          = SkyLight.sym("SLSClearWindowTags")
    static let setWindowResolution:      SetWindowResolutionFn?      = SkyLight.sym("SLSSetWindowResolution")
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
    // Why: SLSSetWindowShape reallocates the window's back-store IOSurface,
    // which invalidates any CGContext bound to the prior surface — every
    // subsequent draw silently lands in a dead surface and the user sees
    // a frozen first-frame border with no updates after move/resize.
    // JankyBorders re-creates the context after every shape change for the
    // same reason. Mutable so applyGeometry can refresh it post-reshape.
    private var context: CGContext

    // Last frame we positioned the overlay at (in screen-points, top-left
    // origin). Compared against the freshly-fetched bounds on every tick
    // to decide whether to re-shape + re-order — both are server round-trips
    // and JankyBorders skips them when the geometry hasn't changed.
    private var lastFrame: CGRect = .zero

    // The overlay starts at alpha=0 (invisible). The first successful
    // draw() flips this to false and bumps the window-wide alpha to 1.
    // Keeps the back-store's default-fill bytes hidden until our first
    // painted pixels land — the "white flash on refresh" fix.
    private var pendingAlphaBump: Bool = true

    // Why: Bridge.swift calls handle.detach() then drops the dict entry,
    // which triggers deinit and would release the same overlayWID twice
    // (the JS detach path is the common case — every focused-window
    // change). Guarded so deinit no-ops when detach already ran.
    private var released: Bool = false

    // Padding around the target frame: the overlay window extends past the
    // target's bounds by this much so strokes drawn at the edge aren't
    // clipped. Borders are typically 1-2px so 16px is plenty of headroom.
    static let padding: CGFloat = 16

    // Resolved once at attach (AX walk to detect toolbar presence). Exposed
    // to JS via the geometry dict's window.radius field — spec authors round
    // their stroke rect with this so the border hugs the actual window
    // shape on Tahoe (Finder=26, Terminal=16, etc.).
    let cachedCornerRadius: Int

    init(id: Int, targetWID: CGWindowID, overlayWID: UInt32, context: CGContext, cornerRadius: Int) {
        self.id = id
        self.targetWID = targetWID
        self.overlayWID = overlayWID
        self.context = context
        self.cachedCornerRadius = cornerRadius
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

        // Why: SLSSetWindowShape (called inside applyGeometry) reallocates
        // the back-store IOSurface at the new size, which (a) invalidates
        // our current CGContext and (b) leaves the new surface filled with
        // WindowServer-default bytes. We MUST reshape first (which also
        // re-creates the context), THEN clear, THEN draw — clearing the
        // pre-reshape context is a no-op against the new surface, and
        // drawing into the pre-reshape context lands in a dead surface.
        // Previous order (clear → reshape → draw) was the root cause of
        // the "freezes after first frame / flashes white on resize" bug.
        if !rectsApproxEqual(overlayFrame, lastFrame) {
            applyGeometry(overlayFrame: overlayFrame)
            lastFrame = overlayFrame
        }

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

        // Why: SLSFlushWindowContentRegion is the authoritative commit for
        // SLWindowContext-bound contexts (JankyBorders uses only this). The
        // CGContext.flush() that used to live here forced a pixmap-style
        // flush that doesn't move bytes to the compositor — extra mach
        // round-trip per frame for no observable effect.
        // NULL region = flush the whole window. We always full-redraw so
        // tracking a dirty rect would just be bookkeeping.
        _ = SkyLightOverlay.flushWindowContentRegion?(cid, overlayWID, nil)

        // First-draw alpha bump. The window was created at alpha=0 to hide
        // the back-store's default-fill bytes until our first painted
        // pixels are committed. Now that the flush has landed, raise alpha
        // to 1 so the user sees the drawn content. Subsequent draws skip
        // this (it's idempotent but the SLS call is a server round-trip).
        if pendingAlphaBump {
            pendingAlphaBump = false
            _ = SkyLightOverlay.setWindowAlpha?(cid, overlayWID, 1)
        }

        _ = SkyLightOverlay.reenableUpdate?(cid)
    }

    /// Tear down. Releases the SLS window (which kills the back-store and
    /// invalidates our CGContext — CG ARC then drops the context ref).
    func detach() {
        if released { return }
        released = true
        let cid = SkyLight.cid
        _ = SkyLightOverlay.releaseWindow?(cid, overlayWID)
    }

    deinit {
        // Last-resort cleanup if detach() wasn't called explicitly. The Bridge
        // detach path is the normal route; this catches scope-drain edge cases
        // where the handle dict is cleared without an explicit detach.
        if released { return }
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

            // Why: SLSSetWindowShape reallocates the back-store IOSurface;
            // the prior CGContext is now bound to a freed surface and any
            // draw call against it is silently dropped. Re-create the
            // context against the fresh surface so the draw pipeline lands
            // in the correct memory. Mirrors JankyBorders' border_init_bind
            // path which calls SLWindowContextCreate after every reshape.
            if let makeContext = SkyLightOverlay.windowContextCreate,
               let ctxRef = makeContext(cid, overlayWID, nil) {
                let fresh = ctxRef.takeRetainedValue()
                fresh.interpolationQuality = .none
                context = fresh
            }
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
        // We REQUIRE the opaque-shape constructor for click-through. The
        // earlier SLSNewWindow + SLSSetWindowEventMask(0) approach is not
        // sufficient — the WindowServer still routes click-to-front
        // activation through hit-testing the window's opaque shape, not
        // the event mask, so the overlay was stealing focus on click.
        // Empty opaque shape = WindowServer sees zero pixels to hit-test
        // against = clicks fall through to whatever's below.
        guard let newWindowWithShape = SkyLightOverlay.newWindowWithOpaqueShape,
              let createEmpty        = SkyLightOverlay.createEmptyRegion,
              let makeContext        = SkyLightOverlay.windowContextCreate,
              let newRegion          = SkyLightOverlay.newRegionWithRect else {
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

        guard let emptyRegion = createEmpty() else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(emptyRegion).release() }

        // JankyBorders/window.h:228-251 — options=13|(1<<18) gives us
        // "ignores cycle" (no cmd-tab / mission-control surface) plus the
        // baseline borderless overlay flags. tag bits (1<<1)=floating,
        // (1<<9)=stays visible across full-screen target. tag_size=64.
        var tags: UInt64 = (1 << 1) | (1 << 9)
        var overlayWID: UInt32 = 0
        let opts: Int32 = 13 | (1 << 18)
        let newErr = newWindowWithShape(cid, 2, region, emptyRegion, opts,
                                        &tags, -9999, -9999, 64, &overlayWID, nil)
        guard newErr == 0, overlayWID != 0 else { return nil }

        // Start invisible (alpha=0). Stays 0 until the FIRST real draw() call
        // commits — then the bridge bumps to 1 once the back-store is known
        // good. This is the only way to dodge the "white flash on refresh"
        // the user sees on every FSEvents reload: between SLSSetWindowShape
        // (which re-allocates the back-store at the new target size with
        // default-fill bytes) and the per-tick clear, there's a 1-frame
        // window where the compositor would show those default-fill bytes.
        // Keeping alpha=0 until the first clean draw lands hides that window.
        _ = SkyLightOverlay.setWindowAlpha?(cid, overlayWID, 0)

        // Enable per-pixel alpha compositing. Without this the back-store's
        // transparent regions composite as opaque background fill — we'd
        // see a (target + padding)-size opaque rect over the target window
        // even though the back-store IS all-transparent. This is why
        // JankyBorders calls SLSSetWindowOpacity(wid, 0) right after
        // creating the window.
        _ = SkyLightOverlay.setWindowOpacity?(cid, overlayWID, false)

        // Re-assert the floating + sticky tags after creation. Without this
        // the overlay can still steal focus on click on some macOS versions
        // — the WindowServer's focus-routing uses the tag bitfield (not
        // just the opaque shape) to decide whether a window is "real" UI.
        // (1<<1) = floating, (1<<9) = visible across full-screen targets.
        // tag_size=64 in BITS — the C signature takes "bits" not bytes.
        var setTags: UInt64   = (1 << 1) | (1 << 9)
        var clearTags: UInt64 = 0
        _ = SkyLightOverlay.setWindowTags?(cid, overlayWID, &setTags, 64)
        _ = SkyLightOverlay.clearWindowTags?(cid, overlayWID, &clearTags, 64)

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

        // Resolve the per-window corner radius once. The AX walk traverses
        // the target's children looking for a toolbar — costs a few ms on
        // first call per app (AX warm-up) and is too expensive to repeat
        // every vsync. Recompute happens only when the stack re-attaches
        // (focus change → new overlay handle), which naturally tracks
        // window-level UI changes.
        let radius = Int(cornerRadius(of: targetID))

        return OverlayHandle(
            id: id,
            targetWID: targetID,
            overlayWID: overlayWID,
            context: context,
            cornerRadius: radius
        )
    }

    /// Per-window corner radius the WindowServer rounds with. Mirrors
    /// `~/.hammerspoon/WindowScape/outline.lua:getCornerRadius` — the
    /// reference implementation the user wants this overlay to match.
    ///
    /// macOS 26 (Tahoe) uses per-style corner radii:
    ///   - 26pt for titled windows WITH a toolbar (Finder, Safari, etc.)
    ///   - 16pt for titled windows WITHOUT a toolbar (Terminal, etc.)
    ///   -  0pt for borderless / system / non-standard windows
    ///
    /// Detection: AX `AXChildren` walked for an `AXRole == "AXToolbar"`
    /// descendant. We don't have a public WindowServer API that returns
    /// the actual server-side rounding radius — SLSWindowIteratorGetCornerRadii
    /// exists but is availability-gated, undocumented, and doesn't return
    /// the toolbar-aware value on Tahoe. The AX-walk path is what the
    /// Hammerspoon outline ships in production.
    ///
    /// Capped at 100ms via AXUIElementSetMessagingTimeout to keep one
    /// unresponsive app from stalling the per-tick overlay loop.
    static func cornerRadius(of wid: CGWindowID) -> CGFloat {
        guard let axEl = WindowsByID.elementFor(windowID: wid) else { return 16 }
        AXUIElementSetMessagingTimeout(axEl, 0.1)

        // Bail early on non-standard / system windows — the Hammerspoon
        // script returns 0 for these (matches Tahoe's borderless rendering).
        if let subrole = axStringAttribute(axEl, kAXSubroleAttribute) {
            if subrole == "AXSystemDialog" { return 0 }
        }
        if let role = axStringAttribute(axEl, kAXRoleAttribute) {
            if role == "AXScrollArea" { return 0 }
        }

        var childrenRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(axEl, kAXChildrenAttribute as CFString, &childrenRef)
        if err == .success, let children = childrenRef as? [AXUIElement] {
            for child in children {
                if axStringAttribute(child, kAXRoleAttribute) == "AXToolbar" {
                    return 26
                }
            }
        }
        return 16
    }

    private static func axStringAttribute(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
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
