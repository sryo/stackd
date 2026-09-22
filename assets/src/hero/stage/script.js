// Hero clip timeline — pure data + a deterministic schedule builder.
//
// Shared by two consumers:
//   - stage.js (in the stackd panel / headless Chrome) drives the editor
//     and calls sd.fs.write with the buffer at every `save` step
//   - gen.mjs (node) writes the demo stack's INITIAL files from FILES so the
//     frame-1 state on disk is the same bytes the editor shows
//
// Honesty invariant: a file written at a save beat is exactly
// `lines.join("\n") + "\n"` of the editor buffer at that moment.

export const FILES = {
  "index.html": [
    '<!doctype html>',
    '<link rel="stylesheet" href="index.css">',
    '<h1>{{ sd.battery.percent }}%</h1>',
  ],
  "index.css": [
    'body {',
    '  display: grid;',
    '  place-content: center;',
    '  height: 100vh;',
    '  font: 26px Inter, sans-serif;',
    '  text-align: center;',
    '  color: #a0a0a0;',
    '}',
    'h1, p { margin: 0 }',
    'h1 { font-size: 84px; color: #f0f0f0 }',
  ],
};

export const FILE_ORDER = ["index.html", "index.css"];

// Beat sheet. `hold` is stillness; `type` expands into per-character events
// with humanized cadence; `save` writes the current file.
export const STEPS = [
  { type: "hold",    ms: 1200 },
  { type: "newline" },
  { type: "hold",    ms: 160 },
  { type: "type",    text: '<p>{{ sd.battery.cycles }} cycles</p>' },
  { type: "hold",    ms: 420 },
  { type: "save" },
  { type: "hold",    ms: 2400 },
  { type: "tab",     file: "index.css" },
  { type: "hold",    ms: 520 },
  { type: "select",  line: 10, text: "#f0f0f0" },
  { type: "hold",    ms: 380 },
  { type: "type",    text: "#30d158" },
  { type: "hold",    ms: 420 },
  { type: "save" },
  { type: "hold",    ms: 3600 },
  { type: "end" },
];

export const TOAST_MS = 560;

// Look-dev only: how long after a save the mock widget flips, approximating
// FSEvents latency (0.2s) + reload debounce (0.3s) + first paint.
export const RELOAD_LAG_MS = 650;

export function serialize(lines) {
  return lines.join("\n") + "\n";
}

// Small LCG so every take has identical keystroke timing.
export function makeRng(seed) {
  let s = (seed >>> 0) || 1;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

const PAUSE_AFTER = { ">": 150, ";": 120, "{": 110, "}": 90, " ": 15, '"': 40 };

// Per-character delay: 42-76ms base plus a small rest after structural
// characters. `prev` is the character just typed (null at the start).
export function charDelay(rng, prev) {
  const base = 42 + rng() * 34;
  const rest = prev == null ? 0 : (PAUSE_AFTER[prev] || 0);
  return Math.round(base + rest);
}

// Expand STEPS into absolute-time events. Returns
//   { events: [{ at, op, ... }], total, saves: [{ at, file }] }
export function buildSchedule(steps = STEPS, seed = 7) {
  const rng = makeRng(seed);
  const events = [];
  const saves = [];
  let t = 0;
  let file = FILE_ORDER[0];
  for (const step of steps) {
    switch (step.type) {
      case "hold":
        t += step.ms;
        break;
      case "newline":
        events.push({ at: t, op: "newline" });
        break;
      case "type": {
        let prev = null;
        for (const ch of step.text) {
          t += charDelay(rng, prev);
          events.push({ at: t, op: "char", ch });
          prev = ch;
        }
        break;
      }
      case "save":
        events.push({ at: t, op: "save" });
        events.push({ at: t + TOAST_MS, op: "toastOff" });
        saves.push({ at: t, file });
        break;
      case "tab":
        file = step.file;
        events.push({ at: t, op: "tab", file });
        break;
      case "select":
        events.push({ at: t, op: "select", line: step.line, text: step.text });
        break;
      case "end":
        events.push({ at: t, op: "end" });
        break;
      default:
        throw new Error("unknown step " + step.type);
    }
  }
  events.sort((a, b) => a.at - b.at);
  return { events, total: t, saves };
}

// Pure buffer model. Apply an event to a state and return the new state.
// Caret is { line, col } (0-based); sel is null or { line, from, to }.
export function initialState() {
  const buffers = {};
  for (const f of FILE_ORDER) buffers[f] = FILES[f].slice();
  const first = FILE_ORDER[0];
  return {
    file: first,
    buffers,
    caret: { line: buffers[first].length - 1, col: buffers[first][buffers[first].length - 1].length },
    sel: null,
    modified: Object.fromEntries(FILE_ORDER.map((f) => [f, false])),
    toast: false,
    saved: Object.fromEntries(FILE_ORDER.map((f) => [f, serialize(FILES[f])])),
    lastSave: null,      // { at, file, contents }
    ended: false,
  };
}

export function applyEvent(state, ev) {
  const s = state;
  const lines = s.buffers[s.file];
  switch (ev.op) {
    case "newline": {
      const { line, col } = s.caret;
      const cur = lines[line];
      lines.splice(line, 1, cur.slice(0, col), cur.slice(col));
      s.caret = { line: line + 1, col: 0 };
      s.sel = null;
      s.modified[s.file] = true;
      break;
    }
    case "char": {
      if (s.sel && s.sel.line === s.caret.line) {
        const l = lines[s.sel.line];
        lines[s.sel.line] = l.slice(0, s.sel.from) + l.slice(s.sel.to);
        s.caret = { line: s.sel.line, col: s.sel.from };
        s.sel = null;
      }
      const { line, col } = s.caret;
      const cur = lines[line];
      lines[line] = cur.slice(0, col) + ev.ch + cur.slice(col);
      s.caret = { line, col: col + 1 };
      s.modified[s.file] = true;
      break;
    }
    case "save": {
      const contents = serialize(lines);
      s.saved[s.file] = contents;
      s.modified[s.file] = false;
      s.toast = true;
      s.lastSave = { at: ev.at, file: s.file, contents };
      break;
    }
    case "toastOff":
      s.toast = false;
      break;
    case "tab": {
      s.file = ev.file;
      const b = s.buffers[s.file];
      s.caret = { line: b.length - 1, col: b[b.length - 1].length };
      s.sel = null;
      break;
    }
    case "select": {
      const li = ev.line - 1;
      const from = lines[li].indexOf(ev.text);
      if (from < 0) throw new Error("select: text not found on line " + ev.line);
      s.sel = { line: li, from, to: from + ev.text.length };
      s.caret = { line: li, col: from + ev.text.length };
      break;
    }
    case "end":
      s.ended = true;
      break;
    default:
      throw new Error("unknown op " + ev.op);
  }
  return s;
}

// Contents written at each save, in order — what the demo stack sees on disk.
export function expectedWrites(schedule = buildSchedule()) {
  const s = initialState();
  const out = [];
  for (const ev of schedule.events) {
    applyEvent(s, ev);
    if (ev.op === "save") out.push({ at: ev.at, file: s.lastSave.file, contents: s.lastSave.contents });
  }
  return out;
}
