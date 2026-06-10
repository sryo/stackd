  // sd.input — keyboard layout signal + curated AX surface for the
  // system-wide focused text element. Replaces the five-call sd.ax.*
  // dance (focused → attribute → parameterizedAttribute → release) muse,
  // palette, and text-expander stacks were doing for every transformation
  // tick.
  //
  //   const f = await sd.input.focusedText();
  //   // → { text, selectedText,
  //   //     selectedRange: { location, length },
  //   //     caretRect: { x, y, w, h } | null,
  //   //     role, subrole, value, pid, app }  | null when no AX-text focus
  //
  //   await sd.input.setSelectedText("hello");        // replace current selection
  //   await sd.input.setSelectedRange(loc, len);      // change selection / move caret
  //
  // Known limitation: Safari / Mail / Firefox WebViews leave
  // kAXSelectedTextAttribute empty even when there's text in the field —
  // selectedText comes back as "" in those cases (the rest of the dict
  // is still populated).
sd.input = {
    layout:    channel("inputLayout"),
    focusedText()           { return request({ type: "input.focusedText" }); },
    setSelectedText(value)  { return request({ type: "input.setSelectedText", value: String(value ?? "") }); },
    setSelectedRange(location, length) {
      return request({
        type: "input.setSelectedRange",
        location: location | 0,
        length:   length   | 0
      });
    }
  };
sd.net = {
    wifi: channel("netWifi"),
    lan:  channel("netLan"),
    // Network reachability — derived from NWPathMonitor on the daemon side.
    //   sd.net.path.subscribe(({ status, interfaces, isConstrained, isExpensive }) => …)
    // status is "satisfied" | "unsatisfied" | "requiresConnection".
    // interfaces is the available route list, ordered by preference, mapped
    // to short strings: "wifi" | "wired" | "cellular" | "loopback" | "other".
    // isConstrained = Low Data Mode; isExpensive = cellular / personal hotspot.
    // The signal stays null until the first NWPath update lands (typically
    // within a few hundred ms of stack load).
    path: channel("netPath"),
    // Aggregate throughput across non-loopback interfaces, polled 1s in
    // the daemon (getifaddrs + if_data byte counters, summed and diffed).
    //   sd.net.throughput.subscribe(({ rxBps, txBps, rxBytes, txBytes }) => …)
    // rxBps / txBps are bytes-per-second over the last second; rxBytes /
    // txBytes are cumulative counters since boot (NIC-reset-dependent).
    // First push lands after the second tick (need two samples to diff) —
    // about 2s after the stack loads. Cadence is `{ interval: N }` on
    // subscribe like other polled channels; daemon stays at 1s natively.
    throughput: channel("netThroughput")
  };
sd.defaults = {
    read(bundleId, key) {
      return request({ type: "defaults.read", bundleId, key });
    }
  };
