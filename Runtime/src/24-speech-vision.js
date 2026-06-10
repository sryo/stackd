  // Text-to-speech via AVSpeechSynthesizer (no TCC, no microphone) plus
  // speech-to-text via SFSpeechRecognizer + AVAudioEngine. STT triggers
  // TWO TCC prompts on first listen():
  //   - Microphone           (NSMicrophoneUsageDescription)
  //   - Speech Recognition   (NSSpeechRecognitionUsageDescription)
  //
  //   sd.speech.speak("hello");
  //   sd.speech.speak("hola", { voice: "es-ES" });            // by locale
  //   sd.speech.speak("text", { voice: "com.apple.voice...", rate: 0.5,
  //                             pitch: 1.1, volume: 0.8 });
  //   sd.speech.stop();                  // immediate
  //   sd.speech.stop({ boundary: "word" }); // wait for current word
  //   const voices = await sd.speech.voices(); // installed voices
  // rate is 0..1 (0.5 ≈ natural), pitch 0.5..2.0, volume 0..1.
  //
  //   const locales = await sd.speech.locales();   // BCP-47 strings
  //
  //   const ear = sd.speech.listen({ locale: "en-US" });
  //   ear.subscribe(({ text, isFinal, segments, error }) => {
  //     if (error) console.warn("speech listen failed:", error);
  //     render(text);                              // partials stream in
  //     if (isFinal) console.log("final:", text);  // recognizer stopped
  //   });
  //   // ...later, to stop early:
  //   await ear.stop();
  //
  // Pass { requireOnDevice: true } to force local-only recognition (audio
  // never leaves the device). Not every locale supports on-device — listen()
  // fires once with { error: "on-device recognition not supported…" } when
  // it doesn't. sd.speech.listen.cancel() stops every active listener
  // owned by this stack in one call (panic-stop shortcut).
sd.speech = (() => {
    // listen() returns a handle synchronously; the underlying id arrives
    // async (the request() round-trip), so subscribers attached before the
    // id resolves get buffered locally and re-bound to the synthesized
    // channel ("speech:listen:<id>") once we have it. Mirrors the
    // sd.bonjour.browse pattern exactly.
    const listen = (opts) => {
      const o = opts || {};
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:            "speech.listen.start",
        locale:          o.locale,
        requireOnDevice: !!o.requireOnDevice
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("speech:listen:" + id);
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
          // best-effort (process-lifetime channels — same trade-off as
          // sd.bonjour.browse).
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "speech.listen.stop", id });
        }
      };
    };
    // Convenience hung off listen() itself — `sd.speech.listen.cancel()`
    // tears down every active listener owned by this stack at once.
    listen.cancel = () => request({ type: "speech.listen.cancel" });
    return {
      speak(text, opts) {
        const o = opts || {};
        return request({
          type: "speech.speak",
          text:   String(text ?? ""),
          voice:  o.voice,
          rate:   o.rate,
          pitch:  o.pitch,
          volume: o.volume
        });
      },
      stop(opts) {
        const o = opts || {};
        return request({ type: "speech.stop", boundary: o.boundary || "immediate" });
      },
      voices()  { return request({ type: "speech.voices" }); },
      locales() { return request({ type: "speech.locales" }); },
      listen
    };
  })();
  // Embedded SQLite (libsqlite3). Minimal wrapper: open / exec / query / close.
  // Default path lands under ~/stackd/stacks/<id>/data/ — absolute paths
  // and ~ paths pass through. FTS4 and FTS5 are compiled into the system
  // libsqlite3 so `CREATE VIRTUAL TABLE ... USING fts5(...)` works.
  //   const db = await sd.sqlite.open("notes.db");
  //   await db.exec("CREATE TABLE IF NOT EXISTS k(v INTEGER)");
  //   await db.exec("INSERT INTO k(v) VALUES (42)");
  //   const r = await db.query("SELECT v FROM k WHERE v > ?", [10]);
  //   await db.close();
  // Consumers: DigUp (FTS-indexed OCR snapshots); persistence-heavy stacks
  // (notes app, quick-search index, history-of-clipboard) where settings.set
  // would be a denormalized mess.
sd.sqlite = {
    async open(path, opts) {
      const o = opts || {};
      const result = await request({
        type: "sqlite.open",
        path: String(path ?? ""),
        mode: o.mode || "readwrite"
      });
      if (!result || !result.handle) return null;
      const handle = result.handle;
      return {
        handle,
        path: result.path,
        exec(sql)              { return request({ type: "sqlite.exec",  handle, sql: String(sql ?? "") }); },
        query(sql, params)     { return request({ type: "sqlite.query", handle, sql: String(sql ?? ""), params: params || [] }); },
        close()                { return request({ type: "sqlite.close", handle }); }
      };
    }
  };
  // Apple's Vision framework. OCR via VNRecognizeTextRequest.
  //   await sd.vision.ocr({ image: dataURL })
  //   await sd.vision.ocr({ image: "/path/to/img.png", languages: ["en"], recognitionLevel: "fast" })
  // Returns { observations: [{ text, confidence, boundingBox: {x,y,w,h} }] }
  // where boundingBox is normalized (0..1) in web-style top-left origin so
  // overlays render directly on top of an <img> with no flip math.
  // Consumers: DigUp (screenshot → OCR → FTS index); ad-hoc "extract text
  // from a screenshot" stack (drop image, copy text to clipboard).
sd.vision = {
    ocr(opts) {
      const o = opts || {};
      return request({
        type: "vision.ocr",
        image: o.image,
        languages: o.languages,
        recognitionLevel: o.recognitionLevel || "accurate"
      });
    },
    // VNDetectFaceRectanglesRequest. Returns
    //   { observations: [{ boundingBox: {x,y,w,h}, confidence,
    //                      roll?, yaw?, pitch? }] }
    // boundingBox is normalized 0..1, top-left origin. Head-pose angles are
    // in radians; absent when Vision can't estimate. No identity / landmarks.
    faces(opts) {
      const o = opts || {};
      return request({ type: "vision.faces", image: o.image });
    },
    // Perceptual hash via VNGenerateImageFeaturePrintRequest. Returns
    //   { print: base64, elementCount, elementType }
    // where `print` is an opaque blob — store it (SQLite, JSON) and later
    // pass two prints to .featurePrintDistance for an L2 similarity score.
    //   const a = await sd.vision.featurePrint({ image: imgA });
    //   const b = await sd.vision.featurePrint({ image: imgB });
    //   const { distance } = await sd.vision.featurePrintDistance(a.print, b.print);
    //   // distance ≈ 0 → near-identical; larger → less similar
    featurePrint(opts) {
      const o = opts || {};
      return request({ type: "vision.featurePrint", image: o.image });
    },
    featurePrintDistance(a, b) {
      return request({ type: "vision.featurePrintDistance", a, b });
    },
    // VNGenerateForegroundInstanceMaskRequest (macOS 14+). Returns
    //   { dataURL: "data:image/png;base64,...", width, height }
    // — the original image with the background made transparent. Returns
    // null on macOS 13 (capability gap, not an error) or when no subject is
    // detected. Same engine Photos.app uses for long-press subject lift.
    subjectMask(opts) {
      const o = opts || {};
      return request({ type: "vision.subjectMask", image: o.image });
    },
    // VNDetectHumanBodyPoseRequest. Returns
    //   { bodies: [{ joints: { nose, leftEye, rightShoulder, ... :
    //                         { x, y, confidence } }, confidence }] }
    // Joint positions are normalized 0..1, top-left origin. Every joint
    // Vision reports is included — including low-confidence ones — so
    // stacks pick their own threshold:
    //   const usable = Object.fromEntries(
    //     Object.entries(body.joints).filter(([_, j]) => j.confidence >= 0.1));
    // Multiple bodies per frame. Each named joint: nose, leftEye, rightEye,
    // leftEar, rightEar, leftShoulder, rightShoulder, neck, leftElbow,
    // rightElbow, leftWrist, rightWrist, leftHip, rightHip, root, leftKnee,
    // rightKnee, leftAnkle, rightAnkle.
    bodyPose(opts) {
      const o = opts || {};
      return request({ type: "vision.bodyPose", image: o.image });
    }
  };
