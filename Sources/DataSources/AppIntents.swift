import Foundation
import AppIntents

// AppIntents bridge — exposes stackd to Shortcuts.app, Spotlight, the
// Action button, Focus filters, and any other system surface that
// auto-discovers AppIntent conformances in the binary.
//
// v1 ships ONE fixed intent — `RunStackdBang` — that wraps the existing
// `stackd bang <name> [k=v ...]` Unix-socket IPC. That's enough to wire
// ANY stack callback into a Shortcuts flow ("when location enters Home →
// run stackd bang `home.arrived`") without per-callback registration.
//
// Why one intent, not one-per-bang: AppIntents expects compile-time
// `struct X: AppIntent { @Parameter var ... }` conformances. stackd's
// bangs are runtime-defined in stack JS, so dynamic registration would
// need either a code-generation step at stack-load time or the as-yet-
// unshipped `AppShortcutsProvider` dynamic-parameter API. v1 takes the
// generic-shape path; a v2 follow-up can generate per-bang intents from
// the manifest's `handles` array.
//
// Process model: AppIntent.perform() runs INSIDE Shortcuts.app (or
// whichever host invoked it), NOT inside the stackd daemon. So perform()
// reaches the daemon via the same Unix-socket IPC the CLI uses
// (`IPCClient.send`). No shared in-process state.

@available(macOS 13.0, *)
struct RunStackdBang: AppIntent {
    static let title: LocalizedStringResource = "Run stackd bang"
    static let description = IntentDescription(
        "Fire a stackd bang to any stacks that handle it. Use bang=\"my.event\" and optional JSON-encoded payload like {\"key\":\"value\"}."
    )

    @Parameter(title: "Bang name", description: "The bang identifier, e.g. 'home.arrived' or 'demo.clicked'.")
    var bang: String

    @Parameter(title: "Payload (JSON)", description: "Optional JSON object of key=value pairs to attach as the bang's detail. Example: {\"hello\":\"world\"}.", default: nil)
    var payload: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run stackd bang \(\.$bang) with payload \(\.$payload)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard RunStackdBangHelpers.isValidBang(bang) else {
            throw NSError(domain: "stackd.appintents", code: 1, userInfo: [
                NSLocalizedDescriptionKey: RunStackdBangHelpers.formatError(
                    "invalid bang name", detail: bang
                )
            ])
        }
        let kv: [String: String]
        do {
            kv = try RunStackdBangHelpers.parsePayloadThrowing(payload)
        } catch {
            throw NSError(domain: "stackd.appintents", code: 2, userInfo: [
                NSLocalizedDescriptionKey: RunStackdBangHelpers.formatError(
                    "could not parse payload", detail: error.localizedDescription
                )
            ])
        }

        var argv: [String] = ["bang", bang]
        for (k, v) in kv { argv.append("\(k)=\(v)") }
        let result = IPCClient.send(argv: argv)
        if result.status != 0 {
            throw NSError(domain: "stackd.appintents", code: 3, userInfo: [
                NSLocalizedDescriptionKey: RunStackdBangHelpers.formatError(
                    "ipc failure", detail: result.response.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            ])
        }
        return .result(value: result.response.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// Pure helpers — extracted so they can be unit-tested without spinning up
// the AppIntents runtime (which can't be hosted in our test harness).
// Everything here is deterministic, no I/O, no AppKit, no IPC.
enum RunStackdBangHelpers {
    /// A bang name must be non-empty, no whitespace, no NUL bytes. We keep
    /// the validator deliberately permissive — bangs are user-defined
    /// strings; the daemon doesn't care about dots vs underscores. The
    /// hard rules are the IPC wire format constraints (NUL is the argv
    /// separator) and the CLI's own argv-style parsing (whitespace would
    /// be ambiguous if the same string was ever shell-quoted).
    static func isValidBang(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            if scalar.value == 0 { return false }
            if scalar.properties.isWhitespace { return false }
        }
        return true
    }

    /// Parse the optional JSON payload string into a `[String: String]`
    /// suitable for the IPC `KEY=VAL` argv tail. Nil or empty → empty
    /// dict. Non-object JSON or any value that isn't string-convertible →
    /// throws. Numbers / bools are stringified (1 → "1", true → "true")
    /// because the IPC layer only speaks strings.
    static func parsePayload(_ s: String?) -> [String: String] {
        return (try? parsePayloadThrowing(s)) ?? [:]
    }

    static func parsePayloadThrowing(_ s: String?) throws -> [String: String] {
        guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return [:]
        }
        guard let data = raw.data(using: .utf8) else {
            throw NSError(domain: "stackd.appintents", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "payload is not valid UTF-8"
            ])
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw NSError(domain: "stackd.appintents", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "payload JSON must be an object, not an array or scalar"
            ])
        }
        var out: [String: String] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
            // The CLI's argv parser splits on the first `=` — so a key
            // containing `=` would parse the wrong way around. Reject it.
            if k.contains("=") {
                throw NSError(domain: "stackd.appintents", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: "payload key '\(k)' must not contain '='"
                ])
            }
            out[k] = stringify(v)
        }
        return out
    }

    private static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        // Nested object / array — round-trip through JSON so the receiver
        // can re-parse it if they want structure back. Stack JS can call
        // JSON.parse(detail.foo) when this happens.
        if let data = try? JSONSerialization.data(withJSONObject: v, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(v)"
    }

    static func formatError(_ kind: String, detail: String) -> String {
        return "stackd.appintents: \(kind) — \(detail)"
    }
}
