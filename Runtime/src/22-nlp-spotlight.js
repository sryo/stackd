  // Apple's NaturalLanguage framework — language ID, tokenization, lemmas,
  // sentence similarity (via NLEmbedding cosine). All synchronous. Useful for
  // Palette command ranking, smart-paste rewrites, "did you mean X" hints.
  //   await sd.nlp.language("Hola mundo")            // → "es"
  //   await sd.nlp.tokens("The quick brown fox")     // → ["The","quick",...]
  //   await sd.nlp.lemmas("running dogs")            // → [{token,lemma,range},...]
  //   await sd.nlp.similarity("open", "launch")      // → 0.72
  // similarity() returns 0 when the embedding model for the detected language
  // isn't on-device (English ships by default; others download on demand).
sd.nlp = {
    language(text)     { return request({ type: "nlp.language",   text: String(text ?? "") }); },
    tokens(text, unit) { return request({ type: "nlp.tokens",     text: String(text ?? ""), unit }); },
    lemmas(text)       { return request({ type: "nlp.lemmas",     text: String(text ?? "") }); },
    similarity(a, b)   { return request({ type: "nlp.similarity", a: String(a ?? ""), b: String(b ?? "") }); }
  };
  // One-shot Spotlight via NSMetadataQuery. `predicate` is the raw
  // NSPredicate format string — kMDItem* attributes joined by AND / OR.
  //   await sd.spotlight.find({
  //     predicate: "kMDItemFSName LIKE[cd] '*.pdf'",
  //     scopes: ["/Users/me/Documents"],     // default: whole computer
  //     limit: 50                             // default: unbounded
  //   })
  //   // → [{ kMDItemFSName, kMDItemPath, kMDItemContentType,
  //   //      kMDItemFSContentChangeDate, kMDItemFSCreationDate,
  //   //      kMDItemFSSize }, ...]
  // Override `attributes` to fetch a different mdkit attribute set.
  // Predicate syntax: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Predicates/AdditionalChapters/Introduction.html
  // Dates are epoch-seconds Numbers; bad predicates will crash the daemon
  // (NSException isn't catchable from Swift) — test your predicate string.
  // Live variant — keeps an NSMetadataQuery alive and pushes the FULL
  // current result-set each time the Spotlight index notifies a change.
  // Same shape as find()'s return: an array of attribute dicts. First emit
  // lands after the initial gather finishes; subsequent emits ride
  // NSMetadataQueryDidUpdate. Stop the query when done.
  //   const q = sd.spotlight.subscribe({
  //     predicate: "kMDItemFSContentChangeDate > $time.today(-1)",
  //     scopes: ["/Users/me/Downloads"]
  //   });
  //   const unsub = q.subscribe(files => render(files));
  //   // ...later...
  //   unsub();        // stop receiving updates (JS-side only)
  //   await q.stop(); // tear down the underlying NSMetadataQuery
  // Mirrors sd.bonjour.browse(): same handle id + per-instance channel
  // ("spotlight:subscribe:<id>") + buffered-subscriber pattern.
sd.spotlight = {
    find(opts) {
      const o = opts || {};
      return request({
        type: "spotlight.find",
        predicate:  o.predicate,
        scopes:     o.scopes,
        attributes: o.attributes,
        limit:      o.limit
      });
    },
    subscribe(opts) {
      const o = opts || {};
      // The handle id arrives async, so subscribers attached before the
      // id resolves get buffered locally and re-bound to the synthesized
      // channel ("spotlight:subscribe:<id>") once we have it. After that,
      // subscribe() goes straight to the underlying channel signal.
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:       "spotlight.subscribe",
        predicate:  o.predicate,
        scopes:     o.scopes,
        attributes: o.attributes,
        limit:      o.limit
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("spotlight:subscribe:" + id);
        for (const fn of localSubs) realCh.subscribe(fn);
        localSubs.clear();
        return id;
      });
      return {
        get id() { return realId; },
        subscribe(fn) {
          if (realCh) return realCh.subscribe(fn);
          localSubs.add(fn);
          // Pre-bind unsubscribe: drop from the local set if the start
          // request hasn't resolved yet. Post-bind unsubscribes are
          // best-effort (the channel signal doesn't expose an unbind hook
          // once we lose the inner unsubscribe ref) — process-lifetime
          // channels mean the cost is one callback ref until stack unload.
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "spotlight.subscribe.stop", id });
        }
      };
    }
  };
  // Bonjour / mDNS — publish a service on the LAN, or browse for one.
  // Backed by Network.framework (NWListener + NWBrowser). On macOS 15+ the
  // first publish/browse triggers a Local Network privacy prompt; the
  // framework raises it — we don't preflight.
  //
  //   const ad = await sd.bonjour.publish({
  //     name: "My Stack",
  //     type: "_http._tcp",
  //     port: 7373,
  //     txt:  { path: "/", role: "primary" }   // optional
  //   });
  //   // ...later...
  //   await ad.stop();
  //
  //   const b = sd.bonjour.browse("_http._tcp");
  //   const unsub = b.subscribe(services => {
  //     // services = [{ name, type, host?, port?, txt }, ...]
  //     // host/port may be absent until a follow-up NWConnection resolves
  //     // the .service endpoint; subscribe yields the full set each time.
  //     render(services);
  //   });
  //   // ...later...
  //   unsub();          // stop receiving updates (JS-side only)
  //   await b.stop();   // tear down the underlying NWBrowser
  //
  // Pairs with sd.httpserver: publish your listener's port and another Mac's
  // stack can find it via browse(). Or browse `_ipp._tcp` for the office
  // printer, `_mqtt._tcp` for an MQTT broker, etc.
  // Permission: "bonjour".
sd.bonjour = {
    // Note on the wire shape: the IPC envelope's `type` key is reserved for
    // primitive dispatch ("bonjour.publish" / "bonjour.browse.start"), so
    // the bonjour service type ("_http._tcp", etc.) travels under
    // `serviceType`. Same workaround as caffeinate.assert/assertionType.
    async publish(opts) {
      const o = opts || {};
      const id = await request({
        type:        "bonjour.publish",
        name:        String(o.name ?? ""),
        serviceType: String(o.type ?? ""),
        port:        o.port | 0,
        txt:         o.txt || null
      });
      if (id == null) return null;
      return {
        id,
        stop() { return request({ type: "bonjour.publish.stop", id }); }
      };
    },
    browse(type) {
      // The handle id arrives async, so subscribers attached before the
      // id resolves get buffered locally and re-bound to the synthesized
      // channel ("bonjour:browse:<id>") once we have it. After that,
      // subscribe() goes straight to the underlying channel signal.
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:        "bonjour.browse.start",
        serviceType: String(type ?? "")
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("bonjour:browse:" + id);
        for (const fn of localSubs) realCh.subscribe(fn);
        localSubs.clear();
        return id;
      });
      return {
        get id() { return realId; },
        subscribe(fn) {
          if (realCh) return realCh.subscribe(fn);
          localSubs.add(fn);
          // Pre-bind unsubscribe: drop from the local set if the start
          // request hasn't resolved yet. Post-bind unsubscribes are
          // best-effort (the channel signal doesn't expose an unbind hook
          // once we lose the inner unsubscribe ref) — process-lifetime
          // channels mean the cost is one callback ref until stack unload.
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "bonjour.browse.stop", id });
        }
      };
    }
  };
  // Pending macOS software updates via `softwareupdate -l`. No TCC; the
  // list verb doesn't need escalation. The shell-out is slow (5-10s —
  // contacts Apple's update catalog), so results are cached process-wide
  // for ~6 hours. Pass `force: true` to refresh now.
  //   const updates = await sd.update.list()
  //   // → [{ label: "macOS Sonoma 14.5-23F79",
  //   //      title: "macOS Sonoma 14.5",
  //   //      version: "14.5",
  //   //      sizeKiB: 7159564,
  //   //      recommended: true,
  //   //      requiresRestart: true }, ...]
  // Empty array = no updates pending. `title`, `version`, `sizeKiB` may be
  // omitted if Apple's output line for that update lacked the field.
sd.update = {
    list(opts) {
      const o = opts || {};
      return request({
        type: "update.list",
        force: !!o.force,
        ttlSeconds: o.ttlSeconds
      });
    }
  };
  // QLThumbnailGenerator one-shot — same preview Finder/Quick Look render
  // for the file at `path` (PDF first page, video poster, audio waveform,
  // app icon, source-code thumbnail). No TCC; file accessibility is the
  // only gate.
  //   const t = await sd.thumbnails.generate({
  //     path: "~/Documents/report.pdf",
  //     width: 256, height: 256,    // points; pixels = size * scale
  //     scale: 2,                    // default: main display backing scale
  //     representation: "all",       // "all" | "thumbnail" | "icon" | "lowQualityThumbnail"
  //     format: "png",               // "png" (default) | "jpeg"
  //     quality: 0.85                // jpeg only
  //   })
  //   // → { dataURL, width, height, type }  or null
  // `type` echoes which QL pass produced the image — handy for telling
  // an icon fallback apart from a real thumbnail.
sd.thumbnails = {
    generate(opts) {
      const o = opts || {};
      return request({
        type: "thumbnails.generate",
        path:           String(o.path ?? ""),
        width:          o.width,
        height:         o.height,
        scale:          o.scale,
        representation: o.representation,
        format:         o.format,
        quality:        o.quality,
        timeoutSeconds: o.timeoutSeconds
      });
    }
  };
