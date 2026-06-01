import CoreGraphics
import Foundation

// Shared dlopen handle for /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight.
//
// SkyLight (the modern WindowServer/CG infrastructure framework) is consumed
// by multiple stackd domains:
//   - Menubar.swift: CGSSetMenuBarVisibility for sd.menubar.suppress
//   - Spaces.swift:  SLSMainConnectionID + SLSCopyManagedDisplaySpaces +
//                    SLSGetActiveSpace + SLSSpaceGetType + SLSCopySpacesForWindows
//   - (future)       hotcorners, per-window-id work, dock peeking, etc.
//
// One file owns the handle. Each consumer declares its own typed symbols via
// `SkyLight.sym("…")` so the symbol surface stays domain-local. dlsym misses
// degrade gracefully (the typed `T?` returns nil; consumers no-op).
//
// Located under Sources/Private/ (sibling to DataSources) to signal "shared
// infrastructure, not a data source." Same pattern would fit a future shared
// MediaRemote.swift / DisplayServices.swift if a second consumer appears.
enum SkyLight {
    static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    /// Type-coerced dlsym. Pattern:
    ///   typealias FooFn = @convention(c) (Int32) -> Void
    ///   static let foo: FooFn? = SkyLight.sym("CGSFoo")
    static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    /// Shared WindowServer connection id. Every CGS/SLS call that addresses
    /// "our session" takes this as the first argument. Resolved once at
    /// process start — calling SLSMainConnectionID more than once costs a
    /// mach round-trip and returns the same value.
    ///
    /// Lives here (instead of per-consumer) so Spaces, Overlay, and future
    /// hotcorners/transactions/menubar code all share one source of truth.
    /// Zero when the SkyLight handle is missing — every consumer that derefs
    /// already no-ops when their typed symbol is nil, so a zero cid never
    /// reaches a live call.
    static let cid: Int32 = {
        typealias MainConnectionFn = @convention(c) () -> Int32
        let fn: MainConnectionFn? = sym("SLSMainConnectionID")
        return fn?() ?? 0
    }()

    /// SLSTransaction* family — atomic batch of geometry/order/level mutations
    /// committed to WindowServer in one server round-trip. Used by:
    ///   - Windows.swift / WindowsByID.beginBatch — sd.windows.batch
    ///   - Overlay.swift / OverlayHandle.applyGeometry — per-tick reshape+order
    ///
    /// Signatures verified against yabai/src/misc/extern.h and JankyBorders/
    /// src/misc/extern.h. The transaction ref returned by `create` is an
    /// opaque CF type (CFTypeRef == AnyObject); callers retain via
    /// `takeRetainedValue()` and pass back into commit/move/order/setLevel.
    ///
    /// Each typed symbol degrades to nil when dlsym misses — every consumer
    /// already guards on optional unwrap before calling.
    enum Transaction {
        typealias CreateFn          = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        typealias CommitFn          = @convention(c) (CFTypeRef, Int32) -> Int32
        typealias MoveWithGroupFn   = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Int32
        typealias OrderWindowFn     = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Int32
        typealias SetWindowLevelFn  = @convention(c) (CFTypeRef, UInt32, Int32) -> Int32

        static let create:         CreateFn?         = SkyLight.sym("SLSTransactionCreate")
        static let commit:         CommitFn?         = SkyLight.sym("SLSTransactionCommit")
        static let moveWithGroup:  MoveWithGroupFn?  = SkyLight.sym("SLSTransactionMoveWindowWithGroup")
        static let orderWindow:    OrderWindowFn?    = SkyLight.sym("SLSTransactionOrderWindow")
        static let setWindowLevel: SetWindowLevelFn? = SkyLight.sym("SLSTransactionSetWindowLevel")
    }
}
