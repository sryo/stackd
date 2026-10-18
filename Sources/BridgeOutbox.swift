import Foundation

/// The scripts one stack's page is owed, in the order they were sent,
/// handed over as one script per run-loop turn. Every Bridge send — channel
/// pushes, RPC responses, bangs, callback fires — goes through it, so the
/// page sees them in call order whichever thread sent them, and a burst (an
/// app switch pushes up to seven channels per stack) costs one evaluation
/// instead of one each. Thread-safe.
final class EvalOutbox {
    private let lock = NSLock()
    private var scripts: [String] = []
    private var idle = true

    /// Queues `script`. True when the outbox was idle, meaning the caller
    /// must schedule the flush that will `take()` it; later sends ride that
    /// flush.
    func append(_ script: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        scripts.append(script)
        guard idle else { return false }
        idle = false
        return true
    }

    /// Everything queued since the last take as one script, nil when
    /// nothing was. The outbox goes idle, so the next send schedules the
    /// next flush — including a send made while this batch is evaluated.
    func take() -> String? {
        lock.lock()
        let batch = scripts
        scripts = []
        idle = true
        lock.unlock()
        return EvalOutbox.script(batch)
    }

    /// One script running `scripts` in order. A lone script goes out
    /// unchanged. In a batch each runs in its own `try`, so a throw doesn't
    /// skip the scripts after it, and is rethrown from a task of its own so
    /// the page's error listeners still see it, as they do for a script
    /// evaluated alone.
    static func script(_ scripts: [String]) -> String? {
        switch scripts.count {
        case 0: return nil
        case 1: return scripts[0]
        default:
            return scripts
                .map { "try{\($0)}catch(e){setTimeout(function(){throw e})}" }
                .joined(separator: "\n")
        }
    }

    /// Runs `block` on main once the current run-loop pass has finished its
    /// work — after the handler, timer or main-queue drain that is running
    /// now, without queueing behind main-queue work still waiting.
    static func atTurnEnd(_ block: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(main)
    }
}

extension Bridge {
    /// `window.__sd_push(channel, json)` — a channel value.
    static func pushScript(channel: String, json: String) -> String {
        "window.__sd_push && window.__sd_push(\"\(channel)\", \(json));"
    }

    /// `window.__sd_response(requestId, json)` — resolves a runtime request.
    static func responseScript(requestId: Int, json: String) -> String {
        "window.__sd_response && window.__sd_response(\(requestId), \(json));"
    }

    /// `window.onBang_<slug>(json)`, the slug being the lowercased name with
    /// every non-alphanumeric character turned into `_`.
    static func bangScript(name: String, json: String) -> String {
        let slug = String(name.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "_"
        })
        return "window.onBang_\(slug) && window.onBang_\(slug)(\(json));"
    }

    /// `globalThis[handler](args…)`. The handler name is looked up as a
    /// string, so quotes in it can't break out; each arg is already JS.
    static func globalScript(handler: String, args: [String]) -> String {
        let h = jsString(handler)
        return "globalThis[\(h)] && globalThis[\(h)](\(args.joined(separator: ", ")));"
    }
}
