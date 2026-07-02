import Foundation

/// Windows primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4+A5). Covers the
/// focused-window + per-windowID + transactional batch surface:
///
///   - `windows.{setFrame, minimize, fullscreen, raise}` — focused-window
///     helpers that operate on the AX focused window of frontmost app.
///     All Bool-returning; deny → false on the write verbs. `.ax`
///     (main-hop) because AXUIElementSetAttributeValue calls deadlock
///     or silently partial-apply when invoked from a non-main thread.
///
///   - `windows.byId.{setFrame, setFrameProbed, isAnimating,
///     cancelAnimation, minimize, fullscreen, raise, focus, close,
///     frame, cornerHints, buttonFrames, info, title, role, subrole,
///     isMinimized, isFullscreen, hasToolbar, isStandard, tabs,
///     focusTab}` — per-CGWindowID surface. Each `.ax` to satisfy the
///     main-thread constraint (setFrame is `.custom` for its
///     settle-time async respond — see the entry comment); setters
///     deny → false, readers deny → null/empty per their canonical
///     shape. `setFrame` with `{duration, easing}` routes through
///     `WindowMotionEngine` (display-link-ticked animation; promise
///     resolves at settle).
///     `setFrameProbed` returns `{ ok, actual }` so callers can detect
///     apps that refused part of the resize (Calculator, browser at
///     min width, fixed-size panels) and build a constraint cache.
///
///   - `windows.byId.snapshot` — per-window snapshot via
///     `CGSHWCaptureWindowList` (AltTab's trick). Synchronous, no TCC,
///     works for hidden / minimized / off-space windows. `.sync` (not
///     `.ax`) because it doesn't touch AX. Distinct from
///     `sd.display.snapshot` (ScreenCaptureKit).
///
///   - `windows.batch.{begin, commit}` — atomic multi-window
///     transaction. `begin` opens a fresh SLSTransaction and installs
///     `WindowsByID.batchSink`; `commit` calls `SLSTransactionCommit`,
///     re-asserts every queued position via AX (the SLS move alone
///     gets clobbered by each app's in-flight resize re-asserting its
///     stale origin — see `WindowsByID.commitBatch` for the full race),
///     and clears the sink. Process-global — if a batch is already
///     open, begin refuses rather than nest, matching the JS-side
///     single-await model. Both hop to main because AX + the SkyLight
///     tx symbols want the WindowServer connection thread.
///
/// Bridge-side scope drain in Bridge.swift commits any leftover batch
/// at unload (`WindowsByID.commitBatch()` no-ops when no batch is open),
/// so a stack that crashed mid-closure can't strand the process-global
/// sink. This file's primitives don't touch any Bridge state directly —
/// `.custom` is used only for the async `respond(...)` hop on the batch
/// entries; the batch sink itself is process-global.
///
/// NOTE: `windows.changed` channel + the per-Bridge `lastWindowsByID` /
/// `windowsChangedPrimed` cache stay in Bridge.swift — they belong to
/// the observer / channel-push side, not the runtime API.
extension Bridge {
    /// Windows primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func windowsPrimitives() -> [Primitive] {
        return [
            // Windows — focused-window helpers operate on the AX focused window
            // of frontmost app. All Bool-returning except byId.frame (returns
            // dict or nil). These hop to main via `.ax` because the underlying
            // AXUIElementSetAttributeValue calls deadlock or silently partial-
            // apply when invoked from a non-main thread (same constraint that
            // moved the .ax.* surface). Concretely: WindowScape's per-tick
            // setFrame loop would land position but drop size on ~half the
            // calls, leaving windows moved-but-not-resized — the "windows
            // resize incorrectly" symptom.
            .ax("windows.setFrame",   permission: "windows", denyValue: false) { _, body in
                Windows.setFocusedFrame(
                    x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                    w: body["w"] as? Double ?? 0, h: body["h"] as? Double ?? 0)
            },
            .ax("windows.minimize",   permission: "windows", denyValue: false) { _, body in Windows.minimizeFocused(body["value"] as? Bool ?? true) },
            .ax("windows.fullscreen", permission: "windows", denyValue: false) { _, body in Windows.fullscreenFocused(body["value"] as? Bool ?? true) },
            .ax("windows.raise",      permission: "windows", denyValue: false) { _, _    in Windows.raiseFocused() },

            // Windows-by-id. setFrame is `.custom` (not `.ax`) because the
            // animated path resolves its promise at settle — potentially
            // hundreds of ms after the RPC arrives — via the motion engine's
            // completion callback. The instant path (no duration/easing)
            // stays byte-for-byte the old behavior, and either way an
            // in-flight animation on the same window is superseded: instant
            // writes cancel it first so the next tick can't clobber them.
            .custom("windows.byId.setFrame", permission: "windows", denyValue: false) { bridge, body, requestId in
                let id = CGWindowID((body["id"] as? Int) ?? 0)
                let frame = CGRect(
                    x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                    width: body["w"] as? Double ?? 0, height: body["h"] as? Double ?? 0)
                let duration = body["duration"] as? Double ?? 0
                let easing = (body["easing"] as? String).flatMap(MotionEasing.init(rawValue:))
                DispatchQueue.main.async { [weak bridge] in
                    guard duration > 0 || easing == .spring else {
                        WindowMotionEngine.shared.instantWriteWins(windowID: id)
                        bridge?.respond(requestId: requestId, value: WindowsByID.setFrame(
                            windowID: id,
                            x: frame.origin.x, y: frame.origin.y,
                            w: frame.size.width, h: frame.size.height))
                        return
                    }
                    WindowMotionEngine.shared.animate(
                        windowID: id, to: frame,
                        duration: duration, easing: easing ?? .easeOutCubic
                    ) { settled in
                        bridge?.respond(requestId: requestId, value: settled)
                    }
                }
            },
            .ax("windows.byId.isAnimating", permission: "windows") { _, body in
                WindowMotionEngine.shared.isAnimating(windowID: CGWindowID((body["id"] as? Int) ?? 0))
            },
            // Cancel = stop ticking, leave the window wherever the last tick
            // put it (the in-flight setFrame promise resolves false).
            .ax("windows.byId.cancelAnimation", permission: "windows", denyValue: false) { _, body in
                WindowMotionEngine.shared.cancel(windowID: CGWindowID((body["id"] as? Int) ?? 0))
            },
            // Probed setFrame: applies the geometry (instant or animated),
            // then reads back what the app actually accepted and runs the
            // FrameLedger verify (one auto-retry, quantum learning, terminal
            // refusal). Returns { ok, actual: {x,y,w,h} | null, refused } —
            // `refused: true` replaces the tiler-side "is it >20px off
            // target?" sweep. With {duration, easing} the probe runs at
            // settle, so the promise IS the post-animation refusal check.
            .custom("windows.byId.setFrameProbed", permission: "windows") { bridge, body, requestId in
                let id = CGWindowID((body["id"] as? Int) ?? 0)
                let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
                let w = body["w"] as? Double ?? 0, h = body["h"] as? Double ?? 0
                let duration = body["duration"] as? Double ?? 0
                let easing = (body["easing"] as? String).flatMap(MotionEasing.init(rawValue:))
                DispatchQueue.main.async { [weak bridge] in
                    let probe: (Bool) -> Void = { ok in
                        WindowsByID.settleProbe(windowID: id, ok: ok, x: x, y: y, w: w, h: h) { result in
                            bridge?.respond(requestId: requestId, value: result)
                        }
                    }
                    guard duration > 0 || easing == .spring else {
                        WindowMotionEngine.shared.instantWriteWins(windowID: id)
                        probe(WindowsByID.setFrame(windowID: id, x: x, y: y, w: w, h: h))
                        return
                    }
                    WindowMotionEngine.shared.animate(
                        windowID: id, to: CGRect(x: x, y: y, width: w, height: h),
                        duration: duration, easing: easing ?? .easeOutCubic
                    ) { settled in
                        // Superseded animations skip the probe — a newer
                        // write owns the window now; verifying against a
                        // stale target would poison the retry budget.
                        if settled {
                            probe(true)
                        } else {
                            bridge?.respond(requestId: requestId, value: [
                                "ok": false, "actual": NSNull(), "refused": false
                            ] as [String: Any])
                        }
                    }
                }
            },
            .ax("windows.byId.minimize",   permission: "windows", denyValue: false) { _, body in WindowsByID.minimize(  windowID: CGWindowID((body["id"] as? Int) ?? 0), body["value"] as? Bool ?? true) },
            .ax("windows.byId.fullscreen", permission: "windows", denyValue: false) { _, body in WindowsByID.fullscreen(windowID: CGWindowID((body["id"] as? Int) ?? 0), body["value"] as? Bool ?? true) },
            .ax("windows.byId.raise",      permission: "windows", denyValue: false) { _, body in WindowsByID.raise(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
            .ax("windows.byId.focus",      permission: "windows", denyValue: false) { _, body in WindowsByID.focus(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
            .ax("windows.byId.close",      permission: "windows", denyValue: false) { _, body in WindowsByID.close(     windowID: CGWindowID((body["id"] as? Int) ?? 0)) },
            .ax("windows.byId.frame",      permission: "windows") { _, body in
                guard let r = WindowsByID.frame(windowID: CGWindowID((body["id"] as? Int) ?? 0)) else { return nil }
                return [
                    "x": Int(r.origin.x), "y": Int(r.origin.y),
                    "w": Int(r.size.width), "h": Int(r.size.height)
                ] as [String: Any]
            },
            .ax("windows.byId.cornerHints", permission: "windows") { _, body in
                WindowsByID.cornerHints(windowID: CGWindowID((body["id"] as? Int) ?? 0))
            },
            // Traffic-light button rects — one AX walk reads close + zoom +
            // minimize button frames so stacks can intercept clicks on the
            // native dots (windowscape routes the yellow dot to its snapshot
            // subsystem). Returns NSNull (→ JS null) when the window is
            // unaddressable; per-button fields are NSNull when that dot doesn't
            // exist on the window (panels, helper windows).
            .ax("windows.byId.buttonFrames", permission: "windows") { _, body in
                WindowsByID.buttonFrames(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
            },
            // Batch reader — one AX lookup, all curated readers in one payload.
            // Replaces 4-9 sequential round-trips at attach/render time.
            .ax("windows.byId.info",        permission: "windows") { _, body in
                WindowsByID.info(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
            },
            // Curated AX readers — per-window properties without round-tripping
            // through `sd.ax.*`. Each maps 1:1 to a WindowsByID static; `.ax`
            // because AX queries must hop to main. nil/false results pass through
            // as JSON null / false, matching the byId.frame contract.
            .ax("windows.byId.title",        permission: "windows") { _, body in
                WindowsByID.title(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
            },
            .ax("windows.byId.role",         permission: "windows") { _, body in
                WindowsByID.role(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
            },
            .ax("windows.byId.subrole",      permission: "windows") { _, body in
                WindowsByID.subrole(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
            },
            .ax("windows.byId.isMinimized",  permission: "windows") { _, body in
                WindowsByID.isMinimized(windowID: CGWindowID((body["id"] as? Int) ?? 0))
            },
            .ax("windows.byId.isFullscreen", permission: "windows") { _, body in
                WindowsByID.isFullscreen(windowID: CGWindowID((body["id"] as? Int) ?? 0))
            },
            .ax("windows.byId.hasToolbar",   permission: "windows") { _, body in
                WindowsByID.hasToolbar(windowID: CGWindowID((body["id"] as? Int) ?? 0))
            },
            .ax("windows.byId.isStandard",   permission: "windows") { _, body in
                WindowsByID.isStandard(windowID: CGWindowID((body["id"] as? Int) ?? 0))
            },
            // Per-window tab list — walks the AXTabGroup child once. Returns
            // [{title, selected}] when a tab group exists, [] if it has no
            // children, NSNull (→ JSON null) when the window has no AXTabGroup.
            .ax("windows.byId.tabs",         permission: "windows") { _, body in
                WindowsByID.tabs(windowID: CGWindowID((body["id"] as? Int) ?? 0)) as Any? ?? NSNull()
            },
            .ax("windows.byId.focusTab",     permission: "windows", denyValue: false) { _, body in
                WindowsByID.focusTab(
                    windowID: CGWindowID((body["id"] as? Int) ?? 0),
                    index: (body["index"] as? Int) ?? 0
                )
            },
            // Per-window snapshot via CGSHWCaptureWindowList (AltTab's trick).
            // Synchronous, no TCC, works for hidden / minimized / off-space
            // windows. Distinct from sd.display.snapshot (ScreenCaptureKit).
            // `quality` is taken as-is — the canonical 0.85 default is declared
            // in Runtime/api.js (`sd.windows.snapshot`). If the field arrives
            // missing here we leave it nil and the encode falls back internally.
            .sync("windows.byId.snapshot",   permission: "windows") { body in
                WindowsByID.snapshot(
                    windowID: CGWindowID((body["id"] as? Int) ?? 0),
                    format:   body["format"]  as? String ?? "png",
                    quality:  body["quality"] as? Double
                )
            },

            // Atomic multi-window transaction. begin opens a fresh SLSTransaction
            // and installs the WindowsByID.batchSink that funnels per-id setFrame
            // calls (and future per-id windows mutations) into it; commit calls
            // SLSTransactionCommit and clears the sink. Process-global — if a
            // batch is already open the begin refuses rather than nest, matching
            // the JS-side single-await model. Hops to main because both AX and
            // the SkyLight tx symbols want the WindowServer connection thread.
            .custom("windows.batch.begin", permission: "windows", denyValue: false) { bridge, _, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    bridge?.respond(requestId: requestId, value: WindowsByID.beginBatch())
                }
            },
            .custom("windows.batch.commit", permission: "windows", denyValue: false) { bridge, _, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    bridge?.respond(requestId: requestId, value: WindowsByID.commitBatch())
                }
            },
        ]
    }
}
