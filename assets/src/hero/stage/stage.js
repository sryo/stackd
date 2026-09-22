// Hero clip stage — a fake-but-calm editor that types a script into a real
// stack's files. The timeline (script.js) starts on the `hero.start` bang;
// every `save` beat writes the editor buffer to disk with sd.fs.write so the
// daemon watching that folder hot-reloads the widget for real.
//
// Debug / look-dev query params (file:// in headless Chrome, or sd://):
//   ?t=<ms>      jump the timeline to an absolute time and freeze
//   ?beat=<n>    jump to a named beat (see BEATS)
//   ?mock=1      draw a stand-in widget at the demo stack's position with the
//                content the demo would show at that time (Chrome only)
//   ?play=1      start the timeline immediately (no bang needed)
//   ?dir=<path>  demo stack folder for saves (the bang detail wins)

import {
  FILE_ORDER, TOAST_MS, RELOAD_LAG_MS,
  buildSchedule, initialState, applyEvent,
} from "./script.js";

const FRAME_W = 1200;
const FRAME_H = 676;

const params = new URLSearchParams(location.search);

const BEATS = {
  1: 700,     // opening hold — complete widget, caret idle
  2: 3200,    // mid-typing of the second line
  3: 4700,    // ⌘S toast (save 1)
  4: 6200,    // stillness after save 1 — widget has its second row
  5: 7600,    // index.css tab, #f0f0f0 selected
  6: 8850,    // ⌘S toast (save 2)
  7: 11800,   // final hold
};

// ── layout ─────────────────────────────────────────────────────────────

const frame = document.getElementById("frame");
function placeFrame() {
  const x = Math.max(0, Math.floor((window.innerWidth - FRAME_W) / 2));
  const y = Math.max(0, Math.floor((window.innerHeight - FRAME_H) / 2));
  frame.style.left = x + "px";
  frame.style.top = y + "px";
}
placeFrame();
window.addEventListener("resize", placeFrame);

// ── tokenizers (per line, tolerant of partially typed lines) ───────────

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function span(cls, text, style) {
  if (!text) return "";
  return `<span class="${cls}"${style ? ` style="${style}"` : ""}>${esc(text)}</span>`;
}

function tokenizeHTML(line) {
  let out = "";
  let i = 0;
  const n = line.length;
  while (i < n) {
    if (line.startsWith("{{", i)) {
      const end = line.indexOf("}}", i + 2);
      out += span("tk-punct", "{{");
      if (end < 0) { out += span("tk-expr", line.slice(i + 2)); break; }
      out += span("tk-expr", line.slice(i + 2, end)) + span("tk-punct", "}}");
      i = end + 2;
      continue;
    }
    if (line.startsWith("<!", i)) {
      const end = line.indexOf(">", i);
      const stop = end < 0 ? n : end + 1;
      out += span("tk-dim", line.slice(i, stop));
      i = stop;
      continue;
    }
    if (line[i] === "<") {
      const m = /^<\/?/.exec(line.slice(i));
      out += span("tk-punct", m[0]);
      i += m[0].length;
      const name = /^[A-Za-z][\w-]*/.exec(line.slice(i));
      if (name) { out += span("tk-tag", name[0]); i += name[0].length; }
      // attributes until the tag closes
      while (i < n) {
        const ws = /^\s+/.exec(line.slice(i));
        if (ws) { out += esc(ws[0]); i += ws[0].length; continue; }
        if (line.startsWith("/>", i)) { out += span("tk-punct", "/>"); i += 2; break; }
        if (line[i] === ">") { out += span("tk-punct", ">"); i += 1; break; }
        const attr = /^[A-Za-z_:][\w:.-]*/.exec(line.slice(i));
        if (attr) { out += span("tk-attr", attr[0]); i += attr[0].length; continue; }
        if (line[i] === "=") { out += span("tk-punct", "="); i += 1; continue; }
        if (line[i] === '"' || line[i] === "'") {
          const q = line[i];
          const end = line.indexOf(q, i + 1);
          const stop = end < 0 ? n : end + 1;
          out += span("tk-string", line.slice(i, stop));
          i = stop;
          continue;
        }
        out += esc(line[i]); i += 1;
      }
      continue;
    }
    // plain text run
    let j = i;
    while (j < n && line[j] !== "<" && !line.startsWith("{{", j)) j++;
    out += esc(line.slice(i, j));
    i = j;
  }
  return out;
}

function cssValue(text) {
  // Hex colours render in their own colour once complete (6 digits).
  return text.replace(/(#[0-9a-fA-F]{6})(?![0-9a-fA-F])|([^#]+|#)/g, (m, hex, rest) => {
    if (hex) return span("tk-hex", hex, `color:${hex}`);
    return esc(rest);
  });
}

function tokenizeCSS(line) {
  let out = "";
  let i = 0;
  const n = line.length;
  const lead = /^\s*/.exec(line)[0];
  out += esc(lead);
  i = lead.length;
  const selm = /^([^{:;}]+)\{/.exec(line.slice(i));
  if (selm) {
    out += span("tk-sel", selm[1]) + span("tk-punct", "{");
    i += selm[0].length;
  }
  while (i < n) {
    const ws = /^\s+/.exec(line.slice(i));
    if (ws) { out += esc(ws[0]); i += ws[0].length; continue; }
    if (line[i] === "}") { out += span("tk-punct", "}"); i += 1; continue; }
    if (line[i] === ";") { out += span("tk-punct", ";"); i += 1; continue; }
    const decl = /^([a-zA-Z-]+)(\s*)(:?)/.exec(line.slice(i));
    if (decl && decl[3]) {
      out += span("tk-prop", decl[1]) + esc(decl[2]) + span("tk-punct", ":");
      i += decl[0].length;
      let j = i;
      while (j < n && line[j] !== ";" && line[j] !== "}") j++;
      out += cssValue(line.slice(i, j));
      i = j;
      continue;
    }
    if (decl && !selm) {
      // bare selector still being typed, or a selector line without `{` yet
      out += span("tk-sel", decl[1] + decl[2]);
      i += decl[0].length;
      continue;
    }
    out += esc(line[i]); i += 1;
  }
  return out;
}

function tokenize(file, line) {
  return file.endsWith(".css") ? tokenizeCSS(line) : tokenizeHTML(line);
}

// ── rendering ──────────────────────────────────────────────────────────

const tabsEl = document.getElementById("tabs");
const codeEl = document.getElementById("code");
const toastEl = document.getElementById("toast");
const mockEl = document.getElementById("mock");

let caretIdleTimer = null;
let caretIdle = true;

function render(state) {
  // tabs
  let tabs = "";
  for (const f of FILE_ORDER) {
    const cls = ["tab", f === state.file ? "active" : "", state.modified[f] ? "modified" : ""].join(" ");
    tabs += `<div class="${cls}"><span>${esc(f)}</span><i class="dot"></i></div>`;
  }
  tabsEl.innerHTML = tabs;

  // lines
  const lines = state.buffers[state.file];
  let rows = "";
  lines.forEach((line, idx) => {
    const isCur = idx === state.caret.line;
    let extra = "";
    if (state.sel && state.sel.line === idx) {
      extra += `<i class="sel" style="left:${state.sel.from}ch;width:${state.sel.to - state.sel.from}ch"></i>`;
    }
    if (isCur) {
      extra += `<i class="caret${caretIdle ? " blink" : ""}" style="left:${state.caret.col}ch"></i>`;
    }
    rows += `<div class="row${isCur ? " current" : ""}"><span class="num">${idx + 1}</span><span class="line">${extra}${tokenize(state.file, line)}</span></div>`;
  });
  codeEl.innerHTML = rows;

  // toast
  toastEl.classList.toggle("on", state.toast);
  toastEl.classList.toggle("off", !state.toast && state.lastSave != null);
}

function markTyping() {
  caretIdle = false;
  clearTimeout(caretIdleTimer);
  caretIdleTimer = setTimeout(() => {
    caretIdle = true;
    const c = codeEl.querySelector(".caret");
    if (c) c.classList.add("blink");
  }, 420);
}

// ── daemon bridge ──────────────────────────────────────────────────────

let sd = null;
try {
  sd = (await import("sd://runtime/api.js")).sd;
} catch (_) {
  sd = null; // headless Chrome look-dev: saves are logged, not written
}

let demoDir = params.get("dir") || "";
const writeLog = [];

async function writeFile(file, contents) {
  const path = demoDir.replace(/\/$/, "") + "/" + file;
  writeLog.push({ file, bytes: contents.length, at: performance.now() });
  if (!sd || !demoDir) {
    console.log("[hero] (no daemon) would write", path, JSON.stringify(contents));
    return;
  }
  const ok = await sd.fs.write(path, contents);
  console.log("[hero] wrote", path, ok);
}

// ── engine ─────────────────────────────────────────────────────────────

const schedule = buildSchedule();
let state = initialState();
let cursor = 0;          // next event index
let t0 = null;           // performance.now() at start
let playing = false;

function runEvent(ev) {
  applyEvent(state, ev);
  if (ev.op === "char" || ev.op === "newline") markTyping();
  if (ev.op === "save") writeFile(state.lastSave.file, state.lastSave.contents);
}

function tick() {
  if (!playing) return;
  const el = performance.now() - t0;
  let changed = false;
  while (cursor < schedule.events.length && schedule.events[cursor].at <= el) {
    runEvent(schedule.events[cursor++]);
    changed = true;
  }
  if (changed) render(state);
  if (cursor >= schedule.events.length) { playing = false; return; }
  requestAnimationFrame(tick);
}

function start(detail) {
  if (playing || state.ended) return;
  if (detail && detail.dir) demoDir = String(detail.dir);
  t0 = performance.now();
  playing = true;
  console.log("[hero] start — writing into", demoDir || "(nowhere)");
  requestAnimationFrame(tick);
}

// Apply every event up to `ms` instantly. Used by ?t= / ?beat= for
// screenshots and retake alignment; saves are NOT written in this mode.
function jumpTo(ms) {
  document.documentElement.classList.add("snapshot");
  state = initialState();
  cursor = 0;
  let mockSaved = { ...state.saved };
  while (cursor < schedule.events.length && schedule.events[cursor].at <= ms) {
    const ev = schedule.events[cursor++];
    applyEvent(state, ev);
    if (ev.op === "save" && ev.at + RELOAD_LAG_MS <= ms) mockSaved[state.lastSave.file] = state.lastSave.contents;
  }
  caretIdle = true;
  render(state);
  if (params.get("mock")) renderMock(mockSaved);
}

// ── look-dev mock widget ──────────────────────────────────────────────

const MOCK_VALUES = { "sd.battery.percent": "87", "sd.battery.cycles": "41" };

function renderMock(saved) {
  const html = saved["index.html"]
    .replace(/<link[^>]*>\n?/, "")
    .replace(/<!doctype html>\n?/i, "")
    .replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_, k) => MOCK_VALUES[k] ?? "");
  const css = saved["index.css"];
  const doc = `<!doctype html><meta charset="utf-8"><style>
    :where(html,body){margin:0;padding:0;background:transparent}
    ${css}
    body{padding:12px;box-sizing:border-box}
  </style>${html}`;
  mockEl.hidden = false;
  mockEl.innerHTML = `<iframe srcdoc="${doc.replace(/"/g, "&quot;")}"></iframe>`;
}

// ── boot ───────────────────────────────────────────────────────────────

render(state);

if (params.has("beat")) {
  jumpTo(BEATS[params.get("beat")] ?? 0);
} else if (params.has("t")) {
  jumpTo(Number(params.get("t")) || 0);
} else if (params.get("play")) {
  if (params.get("mock")) renderMock(state.saved);
  start({ dir: demoDir });
}

if (sd) {
  sd.bang.declare("hero.start").on((detail) => start(detail || {}));
  sd.bang.declare("hero.jump").on((detail) => jumpTo(Number(detail && detail.t) || 0));
}

window.__hero = { state: () => state, schedule, writeLog, jumpTo, start };
