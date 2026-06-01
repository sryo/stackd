import Foundation
import JavaScriptCore

/// Loads `Runtime/api.js` into a JSContext so the template-engine internals
/// (the `__sd*` top-level functions) can be invoked from Swift tests.
///
/// Why JSContext and not WKWebView: the pure parts of the engine
/// (placeholder scanning, expression compilation, scope evaluation) don't
/// need a DOM, and JSContext is sync + fast — a real WKWebView would force
/// async/semaphore plumbing. DOM-coupled functions (text-node mutation,
/// sd-each cloning) need a fuller harness; we'll cross that bridge later.
///
/// Strategy:
///   1. Provide a minimal `window` shim so api.js's top-level assignments
///      (`window.__sd_push = …`) don't throw.
///   2. Strip the single `export` keyword (line 177) since JSContext doesn't
///      grok ES modules — top-level `function` declarations then become
///      globals callable from Swift via `evaluateScript`.
///   3. Stub the native bridge (`window.webkit.messageHandlers.sd.postMessage`)
///      so RPC paths don't NPE if a test wanders into one. Tests should
///      avoid RPC paths anyway, but the stub keeps failures legible.
enum JSHarness {
    private static let shared: JSContext? = makeContext()

    static var context: JSContext {
        guard let ctx = shared else {
            fatalError("JSHarness failed to initialize — see stderr for the cause")
        }
        return ctx
    }

    /// Convenience: evaluate `expr` and return the result as a String, or
    /// nil on JS exception or non-stringable result.
    static func evalString(_ expr: String) -> String? {
        return context.evaluateScript(expr)?.toString()
    }

    /// Reset any per-test mutable state. (No-op today; placeholder for when
    /// tests start mutating shared signals.)
    static func reset() {}

    private static func makeContext() -> JSContext? {
        guard let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, exc in
            let msg = exc?.toString() ?? "<no exception>"
            FileHandle.standardError.write(Data("JS exception: \(msg)\n".utf8))
        }

        // Minimal browser-ish globals so api.js's `window.__sd_*` and
        // `console.*` assignments don't blow up. `webkit.messageHandlers.sd`
        // is a stub — any test that triggers an RPC path will silently no-op,
        // which is fine because we're not testing RPC here.
        // Minimal browser-ish globals so api.js's `window.__sd_*` and
        // `console.*` assignments don't blow up, and DOM/scheduler calls at
        // module-load time become no-ops. We're not testing the DOM-coupled
        // engine paths from Swift; those need a real WKWebView. This shim
        // exists only to let module load complete so the pure functions
        // (__sdScanPlaceholders, __sdCompilePlaceholder) become callable.
        let bootstrap = """
        var window = globalThis;
        var console = {
          log:   function(){}, warn:  function(){}, error: function(){},
          info:  function(){}, debug: function(){}
        };
        window.webkit = { messageHandlers: { sd: { postMessage: function(){} } } };
        window.addEventListener    = function(){};
        window.removeEventListener = function(){};
        // readyState 'complete' steers api.js's bottom-of-file boot past the
        // DOMContentLoaded branch; setTimeout no-op keeps the scheduled
        // __sdCompileTemplates(document) call from ever running.
        var document = {
          readyState: 'complete',
          addEventListener:    function(){},
          removeEventListener: function(){},
          createElement: function(){ return {}; },
          createTextNode: function(){ return {}; },
          createDocumentFragment: function(){ return {}; },
          createComment: function(){ return {}; },
          createTreeWalker: function(){ return { nextNode: function(){ return null; } }; }
        };
        var setTimeout  = function(){ return 0; };
        var setInterval = function(){ return 0; };
        var clearTimeout  = function(){};
        var clearInterval = function(){};
        """
        ctx.evaluateScript(bootstrap)
        if let exc = ctx.exception {
            FileHandle.standardError.write(Data("JSHarness bootstrap exception: \(exc.toString() ?? "?")\n".utf8))
            return nil
        }

        // Load api.js, stripping the single ES-module `export` so JSContext
        // doesn't choke (it parses scripts, not modules).
        let apiPath = "Runtime/api.js"
        guard var source = try? String(contentsOfFile: apiPath, encoding: .utf8) else {
            FileHandle.standardError.write(Data("JSHarness: can't read \(apiPath) (cwd: \(FileManager.default.currentDirectoryPath))\n".utf8))
            return nil
        }
        source = source.replacingOccurrences(of: "export const sd = ", with: "const sd = ")
        // Surface `sd` as a global since stripping `export` doesn't auto-add it.
        // `globalThis.sd = sd` at end of file gives tests access to the public API.
        source += "\n;globalThis.sd = sd;\n"

        ctx.evaluateScript(source)
        if let exc = ctx.exception {
            FileHandle.standardError.write(Data("JSHarness api.js load exception: \(exc.toString() ?? "?")\n".utf8))
            return nil
        }
        return ctx
    }
}
