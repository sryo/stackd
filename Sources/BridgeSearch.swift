import Foundation

/// Search-and-speech primitive group — extracted from Bridge.swift as part
/// of the A1 god-object breakup (architect finding #1). Combined into one
/// file because both clusters share the same handle-table + per-handle
/// channel-name shape and would each be tiny on their own (3 + 6
/// primitives).
///
/// **Spotlight** — `Sources/DataSources/Spotlight.swift`
///   - `spotlight.find` — one-shot NSMetadataQuery, async completion.
///   - `spotlight.subscribe` — long-lived NSMetadataQuery in continuous-
///     update mode. Mints a handle id; per-handle channel name is
///     `"spotlight:subscribe:<id>"`. JS `sd.spotlight.subscribe()` wraps
///     it as `{ id, subscribe(fn), stop() }`.
///   - `spotlight.subscribe.stop` — releases one handle.
///
/// **Speech** — `Sources/DataSources/Speech.swift`
///   - `speech.speak` / `speech.stop` / `speech.voices` / `speech.locales`
///     are pure `.sync(...)` into AVSpeechSynthesizer (no TCC, no
///     microphone — synthesis runs entirely on the local audio device).
///   - `speech.listen.start` mints a Listener handle (SFSpeechRecognizer +
///     AVAudioEngine). Per-handle channel name is `"speech:listen:<id>"`.
///     Final result frame drops the handle so a follow-up stop() is a no-op.
///     First listen() triggers TWO TCC prompts: Microphone and Speech
///     Recognition.
///   - `speech.listen.stop` / `speech.listen.cancel` — release one or all.
///
/// `spotlightLiveHandles`, `nextSpotlightLiveId`, `speechListenHandles`,
/// `nextSpeechListenId`, `respond`, and `push` were widened from
/// fileprivate/private to internal in Bridge.swift to keep these handles
/// pluggable from out-of-file extensions.
extension Bridge {
    /// Spotlight primitives.
    static func spotlightPrimitives() -> [Primitive] {
        return [
            // Spotlight — one-shot NSMetadataQuery. Predicate string is raw
            // NSPredicate format ("kMDItemFSName LIKE[cd] '*.pdf'"); callers
            // must provide valid syntax (malformed predicates crash the daemon
            // — NSException isn't catchable from Swift). Scopes default to the
            // local computer; attributes default to a useful subset.
            .custom("spotlight.find", permission: "spotlight") { bridge, body, requestId in
                let predicate  = body["predicate"]  as? String
                let scopes     = body["scopes"]     as? [String]
                let attributes = body["attributes"] as? [String]
                let limit      = body["limit"]      as? Int
                Spotlight.find(predicate: predicate, scopes: scopes,
                               attributes: attributes, limit: limit) { [weak bridge] result in
                    bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
                }
            },

            // Spotlight — long-lived NSMetadataQuery in continuous-update mode.
            // Each subscribe() mints a handle id; per-handle channel push uses
            // the synthesized name "spotlight:subscribe:<id>". JS
            // sd.spotlight.subscribe(opts) returns { id, subscribe(fn), stop() }
            // that wires the same channel name to the standard signal
            // machinery. First emit fires when the initial Spotlight gather
            // finishes; subsequent emits ride NSMetadataQueryDidUpdate. Same
            // predicate-crash caveat as spotlight.find: a malformed format
            // string raises NSInvalidArgumentException and brings down the
            // daemon — caller validates.
            .custom("spotlight.subscribe", permission: "spotlight") { bridge, body, requestId in
                let predicate  = body["predicate"]  as? String
                let scopes     = body["scopes"]     as? [String]
                let attributes = body["attributes"] as? [String]
                let limit      = body["limit"]      as? Int
                let id = bridge.nextSpotlightLiveId
                bridge.nextSpotlightLiveId += 1
                let channel = "spotlight:subscribe:\(id)"
                let live = Spotlight.LiveQuery(
                    predicate: predicate,
                    scopes:    scopes,
                    attributes: attributes,
                    limit:     limit,
                    onUpdate:  { [weak bridge] entries in
                        guard let bridge = bridge else { return }
                        let json = Bridge.jsonify(entries)
                        bridge.push(channel: channel, json: json)
                    }
                )
                guard let live = live else {
                    // Empty / nil predicate — LiveQuery init? returns nil so
                    // we don't mint a handle. Mirrors the find() empty-predicate
                    // shortcut (returns []) but for subscribe there's nothing
                    // to subscribe to, so the handle id is null and the JS
                    // wrapper's start promise resolves to null.
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                bridge.spotlightLiveHandles[id] = Token { live.stop() }
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("spotlight.subscribe.stop", permission: "spotlight", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let t  = b.spotlightLiveHandles.removeValue(forKey: id) else { return false }
                t.cancel()
                return true
            },
        ]
    }

    /// Speech primitives — TTS + STT. STT triggers TWO TCC prompts on
    /// first listen():
    ///   - Microphone           (NSMicrophoneUsageDescription)
    ///   - Speech Recognition   (NSSpeechRecognitionUsageDescription)
    /// Per-handle channel push for listen() uses the synthesized name
    /// "speech:listen:<id>" (mirrors bonjour.browse).
    static func speechPrimitives() -> [Primitive] {
        return [
            // Text-to-speech via AVSpeechSynthesizer.
            .sync("speech.speak", permission: "speech", denyValue: false) { body in
                Speech.speak(
                    text:   body["text"]   as? String ?? "",
                    voice:  body["voice"]  as? String,
                    rate:   (body["rate"]   as? Double).map { Float($0) },
                    pitch:  (body["pitch"]  as? Double).map { Float($0) },
                    volume: (body["volume"] as? Double).map { Float($0) }
                )
            },
            .sync("speech.stop", permission: "speech", denyValue: false) { body in
                Speech.stop(boundary: body["boundary"] as? String ?? "immediate")
            },
            .sync("speech.voices", permission: "speech", denyValue: [[String: Any]]()) { _ in
                Speech.voices()
            },
            // Supported recognizer locales (BCP-47 strings). One-shot read; the
            // set is static per OS install. No TCC — just an API query.
            .sync("speech.locales", permission: "speech", denyValue: [String]()) { _ in
                Speech.availableLocales()
            },
            // Start a continuous recognizer. Mints an id synchronously; the
            // recognizer + audio engine come up asynchronously inside the
            // Listener (TCC requests are async). Each partial result and the
            // final result are pushed through "speech:listen:<id>".
            .custom("speech.listen.start", permission: "speech") { bridge, body, requestId in
                let locale = body["locale"] as? String
                let requireOnDevice = (body["requireOnDevice"] as? Bool) ?? false
                let id = bridge.nextSpeechListenId
                bridge.nextSpeechListenId += 1
                let channel = "speech:listen:\(id)"
                // Capture id strongly inside the closures — the listener may
                // outlive the immediate respond() because TCC prompts are
                // user-paced. Errors fan out through the same channel as a
                // single push with { isFinal: true, error } so JS callers can
                // treat them uniformly.
                let listener = Speech.Listener(
                    locale: locale,
                    requireOnDevice: requireOnDevice,
                    onResult: { [weak bridge] envelope in
                        guard let bridge = bridge else { return }
                        let json = Bridge.jsonify(envelope)
                        bridge.push(channel: channel, json: json)
                        // Final result → drop the handle so a follow-up stop()
                        // is a no-op (the listener already tore itself down
                        // inside its result callback).
                        if (envelope["isFinal"] as? Bool) == true {
                            bridge.speechListenHandles.removeValue(forKey: id)
                        }
                    },
                    onError: { [weak bridge] message in
                        guard let bridge = bridge else { return }
                        let envelope: [String: Any] = [
                            "text":     "",
                            "isFinal":  true,
                            "segments": [[String: Any]](),
                            "error":    message
                        ]
                        let json = Bridge.jsonify(envelope)
                        bridge.push(channel: channel, json: json)
                        bridge.speechListenHandles.removeValue(forKey: id)
                    }
                )
                bridge.speechListenHandles[id] = Token { listener.stop() }
                listener.start(requireOnDevice: requireOnDevice)
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("speech.listen.stop", permission: "speech", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let t  = b.speechListenHandles.removeValue(forKey: id) else { return false }
                t.cancel()
                return true
            },
            // Convenience — stop every active listener owned by this stack.
            // Equivalent to calling stop() on each handle returned from
            // listen(), but useful for a "panic stop" UI affordance or page
            // teardown shortcut.
            .syncBridge("speech.listen.cancel", permission: "speech", denyValue: false) { b, _ in
                for (_, t) in b.speechListenHandles { t.cancel() }
                b.speechListenHandles.removeAll()
                return true
            },
        ]
    }
}
