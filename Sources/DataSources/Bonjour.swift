import Foundation
import Network

// Bonjour / mDNS via Network.framework — NWListener for publish, NWBrowser
// for discovery. Public since macOS 10.15, cleaner than the older NSNetService
// /  CFNetService stack and the only modern path Apple maintains.
//
// macOS 15+ shows a Local Network privacy prompt the first time a process
// publishes or browses on the LAN. The framework triggers it itself — we
// don't gate behind a TCC preflight here. JS surface docs the behavior.
//
// Two long-lived primitives:
//   publish(...) → PublishHandle    — advertises a service, .stop() retracts.
//   Browser(type:onUpdate:)         — fires onUpdate with the full current
//                                     result set every change; .stop() cancels.
//
// Both wrap an NWListener / NWBrowser respectively and own a private
// DispatchQueue so multiple stacks publishing / browsing don't share a
// single global queue (mirrors HTTPServer.swift's per-instance queue).
//
// Consumers: stackd-to-stackd discovery (publish your sd.httpserver's port +
// .local hostname, another Mac's stack finds it); general mDNS reach
// (browse `_http._tcp` for the office printer, `_mqtt._tcp` for the LAN
// broker, etc.).

enum Bonjour {

    // ── publish ───────────────────────────────────────────────────────────

    /// Long-lived advertisement. Stays up until stop() — drained on stack
    /// unload via Bridge's scope. Returns nil if NWListener init fails
    /// (port already in use is the typical cause).
    final class PublishHandle {
        let name: String
        let type: String
        let port: UInt16
        private var listener: NWListener?
        private let queue: DispatchQueue

        fileprivate init?(name: String, type: String, port: UInt16, txt: [String: String]?) {
            self.name = name
            self.type = type
            self.port = port
            self.queue = DispatchQueue(label: "stackd.bonjour.publish.\(name)")

            // NWListener requires a real socket bound to the given port —
            // we want the advertisement, not the socket, but the framework
            // doesn't expose pure-advertisement. TCP listener with a no-op
            // connection handler is the standard idiom. If port is 0 the
            // OS assigns one; we don't expose that back to the caller
            // because publish() is for fixed-port services (mirroring
            // sd.httpserver where the stack owns the port).
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            do {
                let listener = try NWListener(using: .tcp, on: nwPort)
                let txtRecord = Bonjour.encodeTXT(txt)
                listener.service = NWListener.Service(name: name, type: type, txtRecord: txtRecord)
                // Accept-and-drop: we only want the Bonjour ad. The
                // underlying socket exists so the framework has something
                // to advertise; we never read from it.
                listener.newConnectionHandler = { conn in conn.cancel() }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                FileHandle.standardError.write(Data("stackd: bonjour publish failed for \(name).\(type):\(port) — \(error)\n".utf8))
                return nil
            }
        }

        func stop() {
            listener?.cancel()
            listener = nil
        }
    }

    static func publish(name: String, type: String, port: UInt16, txt: [String: String]?) -> PublishHandle? {
        return PublishHandle(name: name, type: type, port: port, txt: txt)
    }

    // ── browse ────────────────────────────────────────────────────────────

    /// Long-lived browser. `onUpdate` fires with the FULL current result
    /// set on every change (mirrors how NWBrowser reports — incremental
    /// diffs from browseResultsChangedHandler are noisy; consumers want a
    /// snapshot they can render directly). Empty array = no services
    /// currently visible.
    final class Browser {
        let type: String
        private var browser: NWBrowser?
        private let queue: DispatchQueue
        private let onUpdate: ([[String: Any]]) -> Void

        init(type: String, onUpdate: @escaping ([[String: Any]]) -> Void) {
            self.type = type
            self.onUpdate = onUpdate
            self.queue = DispatchQueue(label: "stackd.bonjour.browse.\(type)")

            // Include TXT records so resultDict() can surface them. Default
            // domain (nil) covers .local + any configured search domains.
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: type, domain: nil)
            let params = NWParameters()
            let browser = NWBrowser(for: descriptor, using: params)
            self.browser = browser

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self = self else { return }
                let entries = results.map { Bonjour.resultDict($0, type: type) }
                self.onUpdate(entries)
            }
            // Push an initial empty snapshot once the browser is ready so
            // subscribers see the "no peers yet" state immediately instead
            // of waiting for the first discovery tick.
            browser.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.onUpdate([])
                }
            }
            browser.start(queue: queue)
        }

        func stop() {
            browser?.cancel()
            browser = nil
        }
    }

    // ── pure helpers (testable) ───────────────────────────────────────────

    /// Convert a TXT-record dictionary into an NWTXTRecord. Empty / nil
    /// input returns an empty record (publishing a service with no TXT is
    /// valid and common — most consumers don't read it).
    static func encodeTXT(_ dict: [String: String]?) -> NWTXTRecord {
        var record = NWTXTRecord()
        guard let dict = dict else { return record }
        for (k, v) in dict { record[k] = v }
        return record
    }

    /// Reverse of encodeTXT — pull a [String: String] back out of an
    /// NWTXTRecord for the browse-result dict. Returns empty on absent.
    static func decodeTXT(_ record: NWTXTRecord?) -> [String: String] {
        guard let record = record else { return [:] }
        return record.dictionary
    }

    /// Project an NWBrowser.Result into the JSON-able dict the JS side
    /// expects: { name, type, host?, port?, txt }. Endpoint may carry
    /// a hostPort (rare for raw bonjour metadata — the browser yields
    /// .service endpoints that need a follow-up NWConnection resolve to
    /// surface host/port), in which case those keys are filled in;
    /// otherwise they're omitted. The shape stays the same so JS callers
    /// can read result.host ?? null without branching.
    static func resultDict(_ result: NWBrowser.Result, type: String) -> [String: Any] {
        var entry: [String: Any] = ["type": type]

        // Endpoint → name (.service) or host/port (.hostPort). NWBrowser
        // for a Bonjour descriptor yields .service endpoints; we still
        // handle .hostPort defensively for the case where a future
        // resolver path swaps in a resolved endpoint.
        switch result.endpoint {
        case let .service(name, _, _, _):
            entry["name"] = name
        case let .hostPort(host, port):
            entry["host"] = hostString(host)
            entry["port"] = Int(port.rawValue)
        default:
            break
        }

        // TXT records ride on the metadata side. .bonjour carries the
        // NWTXTRecord; anything else (or absent) decodes to an empty dict
        // so consumers can read result.txt without nil-checking.
        if case let .bonjour(record) = result.metadata {
            entry["txt"] = decodeTXT(record)
        } else {
            entry["txt"] = [String: String]()
        }

        return entry
    }

    /// NWEndpoint.Host → printable string. ipv4/ipv6 stringify directly;
    /// .name uses the bare hostname (the optional interface is dropped —
    /// JS consumers care about the FQDN, not which NIC the resolution
    /// arrived on).
    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "\(addr)"
        case .name(let n, _): return n
        @unknown default:     return ""
        }
    }
}
