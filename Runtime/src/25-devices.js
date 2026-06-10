  // Current location signal: { lat, lon, accuracy, altitude?, heading?, speed?, timestamp }.
  // macOS asks for Location authorization the first time a stack with the
  // "location" permission loads. Returns null until granted + first fix.
sd.location = channel("location");
  // Attached USB devices: [{ vendorID, productID, vendorName?, productName?,
  //   serialNumber?, locationID }, ...]. Fires on attach/detach via IOKit.
sd.usb = channel("usb", []);
  // Mounted volumes via DiskArbitration. One-shot snapshot:
  //   const disks = await sd.disks.list();
  //   // → [{ name, mountPoint, fs?, removable?, ejectable?, size?, internal? }, ...]
  // Live changes via `handles: ["sd.disk.mounted", "sd.disk.unmounted"]` in
  // the stack manifest + window.onBang_sd_disk_mounted(detail) / _unmounted.
sd.disks = {
    list() { return request({ type: "disks.list" }); }
  };
  // Video capture devices: [{ id, name, position, isInUse, manufacturer? }, ...].
  // Fires on connect / disconnect via AVFoundation, and on per-device
  // isInUseByAnotherApplication KVO. Use for "camera in use" indicators
  // (the red Continuity Camera dot equivalent). Enumeration is metadata-only
  // and does NOT trigger the TCC camera prompt — stackd never opens a stream.
  //
  // .frame(opts) is the one-shot capture and the first call that DOES trigger
  // the Camera TCC prompt. Pairs with sd.vision.* — pipe the dataURL
  // straight in for live face/pose/subject extraction.
  //   await sd.camera.frame()
  //   await sd.camera.frame({ deviceId, format: "png" })
  //   await sd.camera.frame({ format: "jpeg", quality: 0.7, timeoutSeconds: 5 })
  //   // → { dataURL: "data:image/jpeg;base64,...", width, height }  (or null)
  //
  // .stream(opts) keeps an AVCaptureSession warm and pushes one frame per
  // tick at the requested fps (default 10, capped at 60). The camera LED
  // stays on for the lifetime of the stream — stop() turns it back off.
  // Same handle-id + subscribe + stop shape as sd.bonjour.browse so a
  // pre-resolve subscriber gets buffered until the channel exists.
  //   const s = sd.camera.stream({ fps: 10 });
  //   const unsub = s.subscribe(({ dataURL, width, height, ts }) => {
  //     img.src = dataURL;
  //   });
  //   // ...later...
  //   unsub();          // stop receiving locally
  //   await s.stop();   // tear the AVCaptureSession down (LED off)
sd.camera = Object.assign(channel("camera", []), {
    frame(opts) {
      const o = opts || {};
      return request({
        type: "camera.frame",
        deviceId:       o.deviceId,
        format:         o.format || "jpeg",
        quality:        o.quality,
        timeoutSeconds: o.timeoutSeconds
      });
    },
    stream(opts) {
      // Mirror sd.bonjour.browse: the handle id resolves async, so any
      // subscribers attached before the channel exists get buffered locally
      // and re-bound to the synthesized channel ("camera:stream:<id>") once
      // we have it. Post-resolve subscribe() goes straight through.
      const o = opts || {};
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:     "camera.stream.start",
        deviceId: o.deviceId,
        format:   o.format || "jpeg",
        quality:  o.quality,
        fps:      o.fps
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("camera:stream:" + id);
        for (const fn of localSubs) realCh.subscribe(fn);
        localSubs.clear();
        return id;
      });
      return {
        get id() { return realId; },
        subscribe(fn) {
          if (realCh) return realCh.subscribe(fn);
          localSubs.add(fn);
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "camera.stream.stop", id });
        }
      };
    }
  });
sd.spaces = {
    all: channel("spaces", []),
    // Spaces this window is on, by CGWindowID — Promise<number[]>.
    // Backed by SLSCopySpacesForWindows.
    windowSpaces(id) { return request({ type: "spaces.windowSpaces", id }); },
    // CGWindowIDs of minimized windows on a space — Promise<number[]>.
    minimizedWindows(spaceID) { return request({ type: "spaces.minimizedWindows", spaceID }); }
  };
sd.menu = {
    // Native NSMenu at the current cursor position. items is an array of
    //   { id, title, checked?, enabled?, separator?, submenu? }
    // Resolves with the picked id, or null on cancel.
    popup(items) { return request({ type: "menu.popup", items: items || [] }); }
  };
