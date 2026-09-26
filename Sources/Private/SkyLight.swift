import CoreGraphics
import Foundation

// Shared dlopen handle for /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight.
//
// SkyLight (the modern WindowServer/CG infrastructure framework) is consumed
// by multiple stackd domains:
//   - Menubar.swift: SLSSetMenuBarInsetAndAlpha for sd.menubar.suppress
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

    /// Every export resolved through `sym`, so `stackd doctor` can check them
    /// against the running OS. A miss is otherwise silent: the consumer's
    /// typed symbol is nil and its primitive no-ops. SkyLightSymbolsTests
    /// fails when a `SkyLight.sym("…")` call and this list disagree.
    static let symbols: [String] = [
        "CGSHWCaptureWindowList",
        "SLPSPostEventRecordTo",
        "SLSCopyManagedDisplaySpaces",
        "SLSCopySpacesForWindows",
        "SLSCopyWindowProperty",
        "SLSGetWindowBounds",
        "SLSGetWindowLevel",
        "SLSMainConnectionID",
        "SLSManagedDisplayGetCurrentSpace",
        "SLSMoveWindowsToManagedSpace",
        "SLSRegisterConnectionNotifyProc",
        "SLSRequestNotificationsForWindows",
        "SLSResetMenuBarSystemOverrideAlphas",
        "SLSSetMenuBarInsetAndAlpha",
        "SLSSetWindowListWorkspace",
        "SLSSetWindowProperty",
        "SLSSpaceGetType",
        "SLSSpaceSetCompatID",
        "SLSTransactionCommit",
        "SLSTransactionCreate",
        "SLSTransactionMoveWindowWithGroup",
        "SLSTransactionOrderWindow",
        "SLSWindowIsOrderedIn",
        "_SLPSSetFrontProcessWithOptions",
    ]

    static func missingSymbols(resolve: (String) -> Bool = { name in
        guard let h = handle else { return false }
        return dlsym(h, name) != nil
    }) -> [String] {
        symbols.filter { !resolve($0) }
    }

    static func doctorLines(missing: [String]) -> [String] {
        guard !missing.isEmpty else {
            return ["✅ skylight: all \(symbols.count) private symbols resolve"]
        }
        return ["❌ skylight: \(missing.count) private symbol(s) missing on this macOS; primitives using them do nothing:"]
            + missing.map { "    \($0)" }
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
        let fn: MainConnectionFn? = SkyLight.sym("SLSMainConnectionID")
        return fn?() ?? 0
    }()

}
