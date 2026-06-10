#!/usr/bin/osascript -l JavaScript
// cgwindows.js — window-state oracle for qa-windowscape.sh.
//
// Hammerspoon-free by design (user direction, 2026-06-09): all observation
// goes through CGWindowListCopyWindowInfo — owner name, bounds, layer, and
// front-to-back z-order, available WITHOUT any TCC prompt (window titles
// are never read; that would need the screen-recording gate). The stackd
// overlay border panel (borderless non-activating NSPanel, .accessory app)
// shows up here as a window owned by "stackd".
//
// JXA bridge note: CGWindowListCopyWindowInfo returns a +1 CFArrayRef that
// JXA cannot auto-bridge. $.CFBridgingRelease segfaults osascript (it is an
// inline/macro in ObjC, not an exported symbol). Binding CFMakeCollectable
// with an explicit signature is the standard workaround.
//
// Usage: osascript -l JavaScript cgwindows.js <command> ['<json-params>']
//   landscape                      → "true"/"false" (primary display)
//   sig       {excluded}           → "id:x,y,w,h|..." stability signature
//   eligible  {excluded}           → "id=Owner[x,y,wxh] ..." left-to-right
//   frontmost {excluded}           → "id owner" of the front eligible window
//   checkI1   {excluded}           → no-overlap invariant
//   checkI2   {excluded}           → I1 + same-row + width-partition
//   checkI3   {excluded,aId,bId,pre} → pair-locality after resize
//   outline   {targetId,tol,excluded} → I4: stackd panel frames the target
//
// params.excluded is a comma-separated owner-name list (windowscape's
// exclusion list). Limitation: entries stored as bundle ids cannot be
// matched against CG owner names; those apps are treated as included.

ObjC.import('Cocoa');
ObjC.bindFunction('CFMakeCollectable', ['id', ['void *']]);

// Owners that are never part of windowscape's tiled set: the daemon's own
// panels plus system chrome that can report layer-0 windows.
const DENY_OWNERS = {
  'stackd': 1, 'Dock': 1, 'Window Server': 1, 'WindowManager': 1,
  'Control Center': 1, 'Notification Center': 1, 'Spotlight': 1,
  'SystemUIServer': 1, 'TextInputMenuAgent': 1, 'CursorUIViewService': 1,
  'Screenshot': 1, 'osascript': 1, 'loginwindow': 1,
  // TCC permission dialog — repositions itself after any tiler placement,
  // so it can never satisfy partition/overlap invariants.
  'universalAccessAuthWarn': 1
};

const COLLAPSED_MAX_H = 14; // windowscape cfg.collapsedWindowHeight (12) + slack

function cgWindows() {
  // 1 = kCGWindowListOptionOnScreenOnly → entries come front-to-back.
  const info = $.CFMakeCollectable($.CGWindowListCopyWindowInfo(1, 0));
  return ObjC.deepUnwrap(info) || [];
}

function primaryScreen() {
  const scr = $.NSScreen.screens.objectAtIndex(0);
  const f = scr.frame, v = scr.visibleFrame;
  // Primary display occupies x∈[0,w), y∈[0,h) in CG top-left coords too,
  // so no NS→CG flip is needed for the containment check below.
  return { w: f.size.width, h: f.size.height,
           visW: v.size.width, visH: v.size.height };
}

function isEligible(w, excluded, prim) {
  const owner = w.kCGWindowOwnerName || '';
  const b = w.kCGWindowBounds;
  if (w.kCGWindowLayer !== 0) return false;
  if (DENY_OWNERS[owner] || excluded[owner]) return false;
  if (w.kCGWindowAlpha === 0) return false;
  if (!b || b.Width < 50 || b.Height <= COLLAPSED_MAX_H) return false;
  const cx = b.X + b.Width / 2, cy = b.Y + b.Height / 2;
  return cx >= 0 && cx < prim.w && cy >= 0 && cy < prim.h;
}

function parseExcluded(params) {
  const out = {};
  String(params.excluded || '').split(',').forEach(e => {
    if (e) out[e] = 1;
  });
  return out;
}

// Oracle mirror of windowscape's tiled set on the primary display,
// sorted left-to-right.
function eligibleWindows(params) {
  const excluded = parseExcluded(params);
  const prim = primaryScreen();
  const out = [];
  for (const w of cgWindows()) {
    if (!isEligible(w, excluded, prim)) continue;
    const b = w.kCGWindowBounds;
    out.push({ id: w.kCGWindowNumber, app: w.kCGWindowOwnerName || '?',
               x: b.X, y: b.Y, w: b.Width, h: b.Height });
  }
  out.sort((a, b) => a.x - b.x);
  return out;
}

const r2 = v => Math.round(v / 2) * 2; // 2px rounding so jitter doesn't flap

function cmdSig(params) {
  return eligibleWindows(params)
    .map(w => `${w.id}:${r2(w.x)},${r2(w.y)},${r2(w.w)},${r2(w.h)}`)
    .sort()
    .join('|');
}

function cmdEligible(params) {
  return eligibleWindows(params)
    .map(w => `${w.id}=${w.app}[${Math.round(w.x)},${Math.round(w.y)},${Math.round(w.w)}x${Math.round(w.h)}]`)
    .join(' ');
}

function cmdFrontmost(params) {
  const excluded = parseExcluded(params);
  const prim = primaryScreen();
  for (const w of cgWindows()) { // front-to-back
    if (isEligible(w, excluded, prim)) {
      return `${w.kCGWindowNumber} ${w.kCGWindowOwnerName}`;
    }
  }
  return 'NONE';
}

function overlapRect(a, b) {
  const ix = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const iy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
  return { w: Math.max(0, ix), h: Math.max(0, iy) };
}

// I1: no real stacking. A seam overlap (thin strip along a shared edge)
// is tolerated up to 8px: apps that snap their size (Terminal rounds to
// character cells) can overhang a neighbor by a few px and the tiler
// rightly leaves that alone. Only an intersection that is "thick" in BOTH
// dimensions counts as windows stacked on each other.
function cmdCheckI1(params) {
  const wins = eligibleWindows(params);
  for (let i = 0; i < wins.length; i++) {
    for (let j = i + 1; j < wins.length; j++) {
      const o = overlapRect(wins[i], wins[j]);
      if (Math.min(o.w, o.h) > 8) {
        return `FAIL overlap ${wins[i].id}(${wins[i].app}) x ${wins[j].id}(${wins[j].app}) ${Math.round(o.w)}x${Math.round(o.h)}px`;
      }
    }
  }
  return 'OK';
}

// I2 layout shape (lenient per harness spec): I1 + same-row (y within 5px;
// height deliberately not asserted — app-specific height refusals are noise)
// + combined width within 15% of the primary work-area width (absorbs the
// snapshots-strip reservation without windowscape-internal state).
function cmdCheckI2(params) {
  const wins = eligibleWindows(params);
  if (wins.length === 0) return 'FAIL no-eligible-windows';
  const i1 = cmdCheckI1(params);
  if (i1 !== 'OK') return i1;

  let minY = Infinity, maxY = -Infinity, sumW = 0;
  for (const w of wins) {
    minY = Math.min(minY, w.y);
    maxY = Math.max(maxY, w.y);
    sumW += w.w;
  }
  if (maxY - minY > 5) {
    return `FAIL not-same-row ymin=${Math.round(minY)} ymax=${Math.round(maxY)} wins=${cmdEligible(params)}`;
  }
  const visW = primaryScreen().visW;
  if (Math.abs(sumW - visW) > 0.15 * visW) {
    return `FAIL width-partition sumW=${Math.round(sumW)} workareaW=${Math.round(visW)} wins=${cmdEligible(params)}`;
  }
  return 'OK n=' + wins.length;
}

// I3 pair-locality. params.pre is a cmdSig() snapshot taken BEFORE growing
// A's right edge by +150px. Expect: A.w grew ~150 (±25), B changed (>5px),
// every OTHER window unchanged (≤5px each of x/y/w/h). Plus I1.
function cmdCheckI3(params) {
  const aId = +params.aId, bId = +params.bId;
  const pre = {};
  for (const m of String(params.pre || '').matchAll(/(\d+):(-?\d+),(-?\d+),(\d+),(\d+)/g)) {
    pre[+m[1]] = { x: +m[2], y: +m[3], w: +m[4], h: +m[5] };
  }
  if (!pre[aId] || !pre[bId]) return 'FAIL bad-pre-sig (A/B missing)';

  const cur = {};
  for (const w of cgWindows()) {
    const b = w.kCGWindowBounds;
    if (b) cur[w.kCGWindowNumber] = { x: b.X, y: b.Y, w: b.Width, h: b.Height,
                                      app: w.kCGWindowOwnerName || '?' };
  }

  const probs = [], offenders = [];
  for (const idStr of Object.keys(pre)) {
    const id = +idStr, p = pre[id], c = cur[id];
    if (!c) {
      if (id !== aId && id !== bId) offenders.push(`${id}(gone)`);
      continue;
    }
    const dx = c.x - p.x, dy = c.y - p.y, dw = c.w - p.w, dh = c.h - p.h;
    if (id === aId) {
      if (Math.abs(dw - 150) > 25) probs.push(`A-width dW=${Math.round(dw)} (wanted ~150)`);
    } else if (id === bId) {
      if (Math.abs(dw) <= 5 && Math.abs(dx) <= 5) {
        probs.push(`B-unchanged dx=${Math.round(dx)} dW=${Math.round(dw)} (expected to absorb)`);
      }
    } else if (Math.abs(dx) > 5 || Math.abs(dy) > 5 || Math.abs(dw) > 5 || Math.abs(dh) > 5) {
      offenders.push(`${id}(${c.app} dx=${Math.round(dx)} dy=${Math.round(dy)} dW=${Math.round(dw)} dH=${Math.round(dh)})`);
    }
  }
  if (offenders.length) probs.push('non-adjacent-changed: ' + offenders.join(' '));
  const i1 = cmdCheckI1(params);
  if (i1 !== 'OK') probs.push(i1);
  return probs.length ? 'FAIL ' + probs.join('; ') : 'OK';
}

// I4: a stackd-owned window frames the target (±tol per edge) and sits
// above it in z-order. On mismatch, reports which window each stackd panel
// DOES frame so wrong-window is distinguishable from missing.
function cmdOutline(params) {
  const tol = params.tol || 16;
  const targetId = +params.targetId;
  const wins = cgWindows();

  let targetIdx = -1, target = null;
  const stackd = [];
  wins.forEach((w, i) => {
    if (w.kCGWindowNumber === targetId) { targetIdx = i; target = w.kCGWindowBounds; }
    if (w.kCGWindowOwnerName === 'stackd') {
      stackd.push({ idx: i, num: w.kCGWindowNumber, layer: w.kCGWindowLayer, b: w.kCGWindowBounds });
    }
  });
  if (targetIdx < 0 || !target) return 'FAIL target-window-not-in-cg-list id=' + targetId;

  const matches = (b, g) =>
    Math.abs(b.X - g.X) <= tol && Math.abs(b.Y - g.Y) <= tol &&
    Math.abs(b.Width - g.Width) <= tol && Math.abs(b.Height - g.Height) <= tol;

  const hit = stackd.find(s => matches(s.b, target));
  if (hit) {
    if (hit.idx < targetIdx) return `OK panel=${hit.num} z=above layer=${hit.layer}`;
    return `FAIL panel-below-target panel=${hit.num} panelIdx=${hit.idx} targetIdx=${targetIdx}`;
  }

  const cands = eligibleWindows(params);
  const what = stackd.map(s => {
    const c = cands.find(c =>
      Math.abs(s.b.X - c.x) <= tol && Math.abs(s.b.Y - c.y) <= tol &&
      Math.abs(s.b.Width - c.w) <= tol && Math.abs(s.b.Height - c.h) <= tol);
    return 'panel#' + s.num + (c
      ? `->win ${c.id} (${c.app})`
      : `->none [${Math.round(s.b.X)},${Math.round(s.b.Y)} ${Math.round(s.b.Width)}x${Math.round(s.b.Height)} layer=${s.layer}]`);
  });
  return 'FAIL no-panel-on-target; stackd-windows=' + (what.length ? what.join('; ') : 'NONE-VISIBLE');
}

function run(argv) {
  if (!argv || argv.length === 0 || !argv[0]) {
    return 'FAIL usage: cgwindows.js <command> [json] — see header comment';
  }
  const cmd = argv[0];
  let params = {};
  if (argv.length > 1 && argv[1]) {
    try { params = JSON.parse(argv[1]); }
    catch (e) { return 'FAIL bad-json-arg: ' + e; }
  }
  switch (cmd) {
    case 'landscape': { const p = primaryScreen(); return String(p.w > p.h); }
    case 'sig':       return cmdSig(params);
    case 'eligible':  return cmdEligible(params);
    case 'frontmost': return cmdFrontmost(params);
    case 'checkI1':   return cmdCheckI1(params);
    case 'checkI2':   return cmdCheckI2(params);
    case 'checkI3':   return cmdCheckI3(params);
    case 'outline':   return cmdOutline(params);
    default:          return 'FAIL unknown-command: ' + cmd;
  }
}
