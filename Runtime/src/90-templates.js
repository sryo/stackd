
// ── Reactive sugar: sd.bind + sd.tpl ────────────────────────────────────────
// `sd.bind(target, signal, fmt?)` is the alternative to writing
// `signal.subscribe(v => el.textContent = fmt(v))` by hand for every binding.
// Target dispatch is by shape:
//   Element                       → set textContent
//   [Element, "html"]             → set innerHTML
//   [Element, "value"]            → set .value (form inputs)
//   [Element, "data-foo"]         → set dataset.foo
//   [Element, "attr.foo"]         → setAttribute("foo", v)
//   [Element, "style.--var"]      → style.setProperty("--var", v)
//   [Element, "class.foo"]        → classList.toggle("foo", !!v)
// `signal` can be a single sd.* channel/signal OR an array of them; the
// formatter is called with each .peek() value spread as args.
function applyToTarget(target, value) {
  if (target instanceof Element) {
    // textContent coerces null/undefined to "null"/"undefined" strings — guard explicitly.
    target.textContent = value == null ? "" : value;
    return;
  }
  if (Array.isArray(target)) {
    const [el, kind] = target;
    if (!(el instanceof Element) || typeof kind !== "string") return;
    if (kind === "html")              el.innerHTML = value == null ? "" : String(value);
    else if (kind === "value")        el.value     = value == null ? "" : value;
    else if (kind.startsWith("data-"))  el.dataset[kind.slice(5)] = value == null ? "" : String(value);
    else if (kind.startsWith("attr."))  { value == null ? el.removeAttribute(kind.slice(5)) : el.setAttribute(kind.slice(5), String(value)); }
    else if (kind.startsWith("style.")) el.style.setProperty(kind.slice(6), value == null ? "" : String(value));
    else if (kind.startsWith("class.")) el.classList.toggle(kind.slice(6), !!value);
  }
}

// All live sd.bind subscriptions, released en masse on `stackd:unload`. Caps
// the worst case of `sd.tpl` leaking subscriptions (detached DOM nodes whose
// bindings stay subscribed) at stack lifetime. Within a stack, callers that
// churn dynamic UI should hold the unsub from sd.bind and call it themselves.
const __sdBindUnsubs = new Set();
window.addEventListener("stackd:unload", () => {
  for (const u of __sdBindUnsubs) { try { u(); } catch (e) {} }
  __sdBindUnsubs.clear();
});

function sdBind(target, source, fmt) {
  const sources = Array.isArray(source) ? source : [source];
  // Type guard: the most common misuse is passing the wrong object (e.g. the
  // namespace `sd.windows` instead of `sd.windows.focused`, or a MenubarItem
  // proxy from sd.menubar.addItem). Catch it loudly instead of throwing
  // deep inside .peek().
  for (const s of sources) {
    if (!s || typeof s.peek !== "function" || typeof s.subscribe !== "function") {
      throw new TypeError(
        "sd.bind: source is not a signal (missing .peek/.subscribe). " +
        "Use a channel like sd.battery or sd.windows.focused, not a namespace or proxy."
      );
    }
  }
  const format  = fmt || ((v) => v);
  const apply = () => applyToTarget(target, format(...sources.map(s => s.peek())));
  const unsubs = sources.map(s => s.subscribe(apply));
  const dispose = () => {
    for (const u of unsubs) u();
    __sdBindUnsubs.delete(dispose);
  };
  __sdBindUnsubs.add(dispose);
  return dispose;
}

// `sd.tpl` — tagged-template helper. Returns an Element (single root) or a
// DocumentFragment (multiple top-level nodes) with `${signal}` interpolations
// auto-bound and `${value}` non-signal interpolations rendered as text.
// Query against the fragment (not its firstElementChild) so a top-level
// `${signal}` interpolation — where the placeholder span IS the root — still
// binds. querySelectorAll on an Element skips itself.
let __sdTplCounter = 0;
function sdTpl(strings, ...exprs) {
  const slotAttr = `data-sd-slot-${__sdTplCounter++}`;
  const placeholders = exprs.map((_, i) => `<span ${slotAttr}="${i}"></span>`);
  const html = strings.reduce((acc, s, i) => acc + s + (placeholders[i] || ""), "");
  const tmpl = document.createElement("template");
  tmpl.innerHTML = html.trim();
  tmpl.content.querySelectorAll(`[${slotAttr}]`).forEach(slot => {
    const idx = +slot.getAttribute(slotAttr);
    const expr = exprs[idx];
    if (expr && typeof expr.subscribe === "function" && typeof expr.peek === "function") {
      sdBind(slot, expr);
    } else {
      slot.textContent = expr == null ? "" : String(expr);
    }
  });
  // If the template produces exactly one Element with no surrounding text
  // nodes, return that Element (common case). Otherwise return the fragment
  // so callers can `.append(...)` multi-root templates.
  const frag = tmpl.content;
  if (frag.childNodes.length === 1 && frag.firstChild instanceof Element) {
    return frag.firstElementChild;
  }
  return frag;
}

sd.bind = sdBind;
sd.tpl  = sdTpl;

// ── Template syntax: {{ sd.battery.percent }} in HTML ──────────────────────
// Walks the document at load time, finds `{{ ... }}` in text content and
// attribute values, compiles each as a JS expression, subscribes to whichever
// sd.* signals it references, and updates the DOM on every fire. Lets simple
// stacks skip writing `sd.bind(...)` and `<script>` entirely.
//
// Signals fall through to their payload via Proxy (see signal() at top of
// file), so `{{ sd.battery.percent }}` reads `.value.percent` directly — no
// `.value` ceremony needed. Before the first sample, array channels
// (windows.all, display.all, apps.running, spaces.all, usb, camera) default
// to `[]`; object channels return `undefined` for unknown keys. Either way,
// no throw — the expression renders empty until the first real sample.
//
// Limitations:
//   - Dependency tracking is regex-based: `{{ sd.battery.percent }}` finds
//     `sd.battery` in the source and subscribes. `const b = sd.battery;
//     b.percent` won't track because the regex never sees the alias. For
//     dynamic usage, drop down to `<script>` + `sd.bind`.
//   - <script> and <style> contents are skipped — they're not display surface.

// Lookup of every signal exposed on `sd.*` that templates can auto-subscribe
// to. Path strings match what the expression author writes (e.g.
// "windows.focused" for `{{ sd.windows.focused.title }}`). Longer paths are
// matched first so "windows.focused" wins over "windows".
//
// The list itself is owned daemon-side in `Sources/Channels.swift` and
// injected into the page as `window.__sd_channels` at document start
// (BEFORE this module loads). That single source of truth also drives the
// Swift-side `Bridge.replayState()` snapshot replay — adding a new channel
// is a one-place edit in Channels.swift; both sides pick it up. Pre-2026-06-04
// these two tables drifted whenever a primitive author touched one and
// forgot the other.
//
// Resolving each jsPath to its `sd.<x>.<y>` signal walks the dotted path at
// module-load time. A path that doesn't resolve is dropped (logs once) —
// usually means the channel was registered Swift-side but the JS API hasn't
// shipped its public `sd.foo` surface yet.
function __sdResolvePath(root, path) {
  const parts = path.split(".");
  let cur = root;
  for (const p of parts) {
    if (cur == null) return undefined;
    cur = cur[p];
  }
  return cur;
}

const __sdSignalPaths = (() => {
  const out = Object.create(null);
  const channels = (typeof window !== "undefined" && window.__sd_channels) || [];
  if (!channels.length) {
    console.warn("[stackd] window.__sd_channels missing — template engine dependency tracking disabled");
    return out;
  }
  for (const ch of channels) {
    if (!ch || !ch.jsPath) continue;
    const sig = __sdResolvePath(sd, ch.jsPath);
    if (sig == null) {
      console.warn("[stackd] channel registered without JS surface:", ch.jsPath);
      continue;
    }
    out[ch.jsPath] = sig;
  }
  return out;
})();

// Sort once, longer-first, so "windows.focused" matches before "windows" —
// otherwise the shorter prefix would always win and the longer path's signal
// would never get subscribed.
const __sdSignalPathsSorted = Object.keys(__sdSignalPaths)
  .sort((a, b) => b.length - a.length);

function __sdCompilePlaceholder(expr) {
  // Compile with (sd, item, index) signature. Non-loop placeholders just
  // don't reference item/index — bound to undefined when called outside a
  // sd-each context. Lets the same compiled fn work in both modes.
  let fn;
  try {
    fn = new Function("sd", "item", "index", "return (" + expr + ");");
  } catch (e) {
    console.error("[stackd] template parse error in {{", expr.trim(), "}}:", String(e));
    fn = () => "";
  }
  const deps = new Set();
  for (const path of __sdSignalPathsSorted) {
    const re = new RegExp("\\bsd\\." + path.replace(/\./g, "\\.") + "\\b");
    if (re.test(expr)) deps.add(__sdSignalPaths[path]);
  }
  return { fn, deps: [...deps] };
}

function __sdEvalWithScope(compiled, item, index) {
  try {
    const v = compiled.fn(sd, item, index);
    return v == null ? "" : String(v);
  } catch (e) {
    return "";
  }
}

function __sdEvalPlaceholder(compiled) {
  // The signal Proxy fall-through means missing payload keys return
  // `undefined` (or `[]` for array-defaulted channels), not throw — so this
  // try/catch is now belt-and-suspenders for genuine expression errors
  // (TypeError calling a non-function, RangeError on stringify, etc.), not
  // the common null-payload-on-first-read case it was originally written for.
  return __sdEvalWithScope(compiled, undefined, undefined);
}

// Wire an applyFn to a set of dependent signals: paint once, subscribe each
// dep, register every unsub with __sdBindUnsubs so stack unload tears them
// down. Used by all four template paths (text nodes, attributes, sd-each,
// sd-if) — each supplies its own applyFn (DOM write strategies differ) but
// the subscription + cleanup plumbing is identical.
function __sdSubscribeAll(deps, applyFn) {
  applyFn();
  for (const sig of deps) {
    const unsub = sig.subscribe(applyFn);
    __sdBindUnsubs.add(unsub);
  }
}

// Scan a raw string for `{{ … }}` placeholders. Returns null when no
// placeholders are present, otherwise:
//   parts:  alternating literal-string / null slots — concat by replacing
//           each null with the eval of slots[slotIdx++].
//   slots:  compiled placeholder objects, one per { fn, deps }.
//   deps:   union of all slot deps (the set you subscribe to).
// Shared between __sdProcessAttribute (single-attr concat) and
// __sdProcessEachElement (per-text-or-attribute concat inside a clone).
function __sdScanPlaceholders(raw) {
  const re = /\{\{([\s\S]+?)\}\}/g;
  const parts = [];
  const slots = [];
  const deps = new Set();
  let lastIndex = 0;
  let m;
  while ((m = re.exec(raw)) !== null) {
    parts.push(raw.slice(lastIndex, m.index));
    const c = __sdCompilePlaceholder(m[1]);
    slots.push(c);
    parts.push(null);
    for (const d of c.deps) deps.add(d);
    lastIndex = m.index + m[0].length;
  }
  if (slots.length === 0) return null;
  parts.push(raw.slice(lastIndex));
  return { parts, slots, deps };
}

function __sdProcessTextNode(textNode) {
  const raw = textNode.nodeValue;
  const re = /\{\{([\s\S]+?)\}\}/g;
  const frag = document.createDocumentFragment();
  let lastIndex = 0;
  let m;
  let hadMatch = false;
  while ((m = re.exec(raw)) !== null) {
    hadMatch = true;
    if (m.index > lastIndex) {
      frag.appendChild(document.createTextNode(raw.slice(lastIndex, m.index)));
    }
    const slot = document.createElement("span");
    const compiled = __sdCompilePlaceholder(m[1]);
    __sdSubscribeAll(compiled.deps, () => {
      slot.textContent = __sdEvalPlaceholder(compiled);
    });
    frag.appendChild(slot);
    lastIndex = m.index + m[0].length;
  }
  if (!hadMatch) return;
  if (lastIndex < raw.length) {
    frag.appendChild(document.createTextNode(raw.slice(lastIndex)));
  }
  textNode.parentNode.replaceChild(frag, textNode);
}

function __sdProcessAttribute(el, attrName, raw) {
  // parts[i] is either a literal string or null (meaning "splice in
  // slots[slotIdx++]"). Cheap concat on every fire.
  const scanned = __sdScanPlaceholders(raw);
  if (!scanned) return;
  const { parts, slots, deps } = scanned;
  __sdSubscribeAll(deps, () => {
    let out = "";
    let slotIdx = 0;
    for (const p of parts) out += p === null ? __sdEvalPlaceholder(slots[slotIdx++]) : p;
    el.setAttribute(attrName, out);
  });
}

// ── sd-each list rendering ─────────────────────────────────────────────────
// `<li sd-each="sd.camera">{{ item.name }} ({{ index }})</li>` clones the
// element once per array item. `item` and `index` are bound inside any
// `{{ … }}` (text content or attributes) on the element or its descendants.
//
// Reconciliation modes:
//   - WITHOUT `sd-key`: full re-render on every signal fire — every active
//     clone removed, all new clones inserted. Cheap for short stable lists
//     (cameras, displays, USB, focused-app windows). The historical default.
//   - WITH `sd-key="<expr>"`: keyed reconciliation. The expression is
//     evaluated per item with `item` + `index` in scope; matching keys reuse
//     the existing DOM node (text/attribute slots re-applied), missing keys
//     are removed, new keys are cloned. DOM-stable: focus, scroll, in-flight
//     animations, and IME composition survive list updates. Use when the
//     list size is significant (`sd.windows.all`, ~50 entries) or when DOM
//     state matters across pushes.
//
// Limitations (v1):
//   - Nested sd-each not supported; an inner loop is silently ignored with a
//     console.warn. Compose a separate stack or drop down to JS.
//   - sd-if on the same element as sd-each is ignored (warn). Filter inside the
//     each expression instead: `sd-each="(sd.x || []).filter(…)"`.
//   - sd-if INSIDE a sd-each subtree is not honored per-clone — the each's
//     clones don't re-run sd-if compilation. Use a `{{ cond ? … : '' }}`
//     placeholder for per-item conditionals.
//   - sd-key MUST produce primitive keys (string/number/bool). Object keys
//     short-circuit to unkeyed behavior with a console.warn.

function __sdProcessEachElement(el) {
  const expr = el.getAttribute("sd-each");
  const sourceCompiled = __sdCompilePlaceholder(expr);
  const keyExprRaw = el.getAttribute("sd-key");
  const keyCompiled = keyExprRaw ? __sdCompilePlaceholder(keyExprRaw) : null;
  const anchor = document.createComment(" sd-each:" + expr + " ");
  el.parentNode.insertBefore(anchor, el);
  el.remove();
  el.removeAttribute("sd-each");
  if (keyExprRaw) el.removeAttribute("sd-key");

  // Pre-scan template (the detached `el`) for `{{ … }}` in text + attributes.
  // Record paths so we can re-locate each slot in a fresh clone without
  // re-scanning. Path is an array of childNodes-indices from the template root.
  const textOps = [];
  const attrOps = [];
  const allDeps = new Set(sourceCompiled.deps);
  const SKIP_TAGS = new Set(["SCRIPT", "STYLE"]);

  function scanPlaceholders(raw) {
    const got = __sdScanPlaceholders(raw);
    if (!got) return null;
    for (const d of got.deps) allDeps.add(d);
    return got;
  }

  function scan(node, path) {
    if (node.nodeType === 3) { // TEXT
      const got = scanPlaceholders(node.nodeValue);
      if (got) textOps.push({ path, parts: got.parts, slots: got.slots });
      return;
    }
    if (node.nodeType !== 1) return;
    if (SKIP_TAGS.has(node.nodeName)) return;
    // Nested sd-each: don't recurse; v1 limitation.
    if (node !== el && node.hasAttribute && node.hasAttribute("sd-each")) {
      console.warn("[stackd] nested sd-each not supported; ignoring inner loop on", node.nodeName);
      return;
    }
    for (const attr of Array.from(node.attributes)) {
      if (attr.name === "sd-each") continue;
      const got = scanPlaceholders(attr.value);
      if (got) attrOps.push({ path, attrName: attr.name, parts: got.parts, slots: got.slots });
    }
    for (let i = 0; i < node.childNodes.length; i++) {
      scan(node.childNodes[i], path.concat([i]));
    }
  }
  scan(el, []);

  function findByPath(root, path) {
    let n = root;
    for (const i of path) {
      if (!n || !n.childNodes) return null;
      n = n.childNodes[i];
    }
    return n;
  }

  function applyParts(parts, slots, item, index) {
    let out = "";
    let slotIdx = 0;
    for (const p of parts) {
      if (p === null) { out += __sdEvalWithScope(slots[slotIdx], item, index); slotIdx++; }
      else            { out += p; }
    }
    return out;
  }

  let active = [];                  // ordered DOM nodes currently rendered
  let activeKeys = [];              // parallel array of keys (or null if unkeyed)

  // Build or update a clone in place: re-apply every text + attribute slot
  // against the current `item` / `index`. Returns the node (possibly the
  // input one in the keyed-reuse case).
  function applyTemplateOps(node, item, index) {
    // sd-on:click handlers inside this clone read item/index from the
    // nearest ancestor's __sdScope at click time. Re-stamped on keyed reuse
    // so a reordered clone fires with its CURRENT item, not the one it was
    // born with.
    node.__sdScope = { item, index };
    for (const op of textOps) {
      const target = findByPath(node, op.path);
      if (!target || target.nodeType !== 3) continue;
      target.nodeValue = applyParts(op.parts, op.slots, item, index);
    }
    for (const op of attrOps) {
      const target = findByPath(node, op.path);
      if (!target || target.nodeType !== 1) continue;
      target.setAttribute(op.attrName, applyParts(op.parts, op.slots, item, index));
    }
    return node;
  }

  function evalKey(item, index) {
    let k;
    try { k = keyCompiled.fn(sd, item, index); } catch (e) { k = undefined; }
    const t = typeof k;
    if (t === "string" || t === "number" || t === "boolean") return k;
    // Non-primitive keys (objects, null, undefined) can't be Map keys
    // reliably — short-circuit. Warn once per render cycle; the caller's
    // unkeyed branch handles the actual rendering.
    if (!evalKey._warned) {
      console.warn("[stackd] sd-each: sd-key produced non-primitive value; falling back to unkeyed render");
      evalKey._warned = true;
    }
    return undefined;
  }

  function renderUnkeyed(arr) {
    for (const n of active) n.remove();
    active = [];
    activeKeys = [];
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      const clone = applyTemplateOps(el.cloneNode(true), item, i);
      anchor.parentNode.insertBefore(clone, anchor.nextSibling);
      active.push(clone);
    }
  }

  function renderKeyed(arr) {
    // Index existing clones by their key for O(n) reuse lookup.
    const byKey = new Map();
    for (let i = 0; i < active.length; i++) {
      const k = activeKeys[i];
      if (k !== undefined) byKey.set(k, active[i]);
    }
    // First pass: collect keys, fall back to unkeyed if any key is bad.
    const keys = new Array(arr.length);
    for (let i = 0; i < arr.length; i++) {
      const k = evalKey(arr[i], i);
      if (k === undefined) { renderUnkeyed(arr); return; }
      keys[i] = k;
    }
    // Second pass: walk the new array in order; reuse existing nodes
    // where keys match (re-applying slot content), clone for new keys.
    // Insertion cursor starts at anchor — each placed node becomes the
    // new cursor so order matches `arr`.
    const newActive = new Array(arr.length);
    const reused = new Set();
    let cursor = anchor;
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      const k = keys[i];
      let node = byKey.get(k);
      if (node) {
        reused.add(node);
        applyTemplateOps(node, item, i);
        // Move into position only if not already adjacent — preserves
        // focus / scroll / animation state when order is stable.
        if (cursor.nextSibling !== node) {
          anchor.parentNode.insertBefore(node, cursor.nextSibling);
        }
      } else {
        node = applyTemplateOps(el.cloneNode(true), item, i);
        anchor.parentNode.insertBefore(node, cursor.nextSibling);
      }
      cursor = node;
      newActive[i] = node;
    }
    // Drop any active nodes that aren't part of the new list.
    for (const n of active) {
      if (!reused.has(n)) n.remove();
    }
    active = newActive;
    activeKeys = keys;
  }

  function render() {
    evalKey._warned = false;
    let arr;
    try { arr = sourceCompiled.fn(sd, undefined, undefined); } catch (e) { arr = null; }
    if (!Array.isArray(arr)) {
      for (const n of active) n.remove();
      active = [];
      activeKeys = [];
      return;
    }
    if (keyCompiled) renderKeyed(arr);
    else             renderUnkeyed(arr);
  }

  __sdSubscribeAll(allDeps, render);
}

// ── sd-if conditional rendering ────────────────────────────────────────────
// `<li sd-if="!sd.camera || sd.camera.length === 0">no cameras</li>` removes
// the element from the DOM when the expression is falsy, re-attaches it when
// truthy. Expression is re-evaluated on every signal fire whose channel it
// references (same regex-based dep detection as templates). The element keeps
// its compiled `{{ … }}` subscriptions across toggles — when detached, those
// fire harmlessly into a disconnected DOM; on re-attach the subtree already
// reflects current state.
//
// Setup runs BEFORE the text/attr walks so the anchor is in place, but
// detachment is deferred until AFTER those walks — that lets the regular
// placeholder compilation visit the (still-attached) subtree, so a falsy-at-
// load-time element still has its internal `{{ }}` bindings wired up for when
// it becomes truthy later.
function __sdSetupIfElement(el) {
  const expr = el.getAttribute("sd-if");
  el.removeAttribute("sd-if");
  const compiled = __sdCompilePlaceholder(expr);
  const anchor = document.createComment(" sd-if:" + expr + " ");
  el.parentNode.insertBefore(anchor, el);

  function evalTruthy() {
    try { return !!compiled.fn(sd, undefined, undefined); }
    catch (e) { return false; }
  }
  function render() {
    const truthy = evalTruthy();
    if (truthy && !el.isConnected) {
      anchor.parentNode.insertBefore(el, anchor.nextSibling);
    } else if (!truthy && el.isConnected) {
      el.remove();
    }
  }
  return { render, deps: compiled.deps };
}

// ── sd-on:click declarative click handling ─────────────────────────────────
// `<button sd-on:click="addGlass()">+1</button>` makes the element clickable
// with zero plumbing. Panels are click-through by default, so behind the
// attribute the runtime (1) tracks the element's viewport rect and pushes
// the set to the daemon via window.setInteractiveRects, where a daemon-
// internal mouseMoved observer flips the panel's click-through as the
// pointer enters/leaves, and (2) dispatches the click through ONE delegated
// document listener — clones from sd-each can't carry listeners through
// cloneNode, but data- attributes survive it, so handlers are looked up by
// data-sd-on-click id at click time. Inside sd-each, `item` and `index` are
// in scope (read from the clone's __sdScope, stamped by applyTemplateOps).
//
// Expressions share __sdCompilePlaceholder with {{ }} — same globals, same
// (sd, item, index) signature. Errors are console.error'd, not swallowed:
// a click the author wired IS the thing being debugged.
//
// Known limitation: rects refresh on DOM mutations, scroll/resize, panel
// moves (stackd:frame), and transition/animation end — but not mid-CSS-
// animation. A button that drifts while animating has a stale hover gate
// until the animation settles.
const __sdOnHandlers = new Map();
let __sdOnNextId = 1;
let __sdInteractiveInstalled = false;
let __sdRectsScheduled = false;
let __sdLastRectsPayload = null;

function __sdSetupOnClickElement(el) {
  const expr = el.getAttribute("sd-on:click");
  el.removeAttribute("sd-on:click");
  if (!expr || !expr.trim()) return;
  const id = String(__sdOnNextId++);
  __sdOnHandlers.set(id, __sdCompilePlaceholder(expr));
  el.setAttribute("data-sd-on-click", id);
  el.setAttribute("data-sd-interactive", "");
  __sdEnsureInteractiveTracking();
}

function __sdDispatchOnClick(target) {
  let el = target;
  while (el && (!el.hasAttribute || !el.hasAttribute("data-sd-on-click"))) {
    el = el.parentElement;
  }
  if (!el) return;
  const compiled = __sdOnHandlers.get(el.getAttribute("data-sd-on-click"));
  if (!compiled) return;
  let scopeEl = el;
  while (scopeEl && !scopeEl.__sdScope) scopeEl = scopeEl.parentElement;
  const scope = scopeEl ? scopeEl.__sdScope : { item: undefined, index: undefined };
  try {
    compiled.fn(sd, scope.item, scope.index);
  } catch (e) {
    console.error("[stackd] sd-on:click failed:", String(e));
  }
}

function __sdScheduleInteractiveRects() {
  if (__sdRectsScheduled) return;
  __sdRectsScheduled = true;
  const raf = typeof requestAnimationFrame === "function"
    ? requestAnimationFrame
    : (fn) => setTimeout(fn, 16);
  raf(() => {
    __sdRectsScheduled = false;
    if (typeof document.querySelectorAll !== "function") return;
    const rects = [];
    for (const el of document.querySelectorAll("[data-sd-interactive]")) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        rects.push({ x: r.left, y: r.top, w: r.width, h: r.height });
      }
    }
    // Dedupe — MutationObserver fires on every template re-render; only
    // bother the daemon when the rect set actually changed.
    const payload = JSON.stringify(rects);
    if (payload === __sdLastRectsPayload) return;
    __sdLastRectsPayload = payload;
    request({ type: "window.setInteractiveRects", rects });
  });
}

function __sdEnsureInteractiveTracking() {
  if (__sdInteractiveInstalled) return;
  __sdInteractiveInstalled = true;
  document.addEventListener("click", (ev) => __sdDispatchOnClick(ev.target));
  const schedule = () => __sdScheduleInteractiveRects();
  // typeof guards: the JSC test harness has no DOM observers; tracking is
  // a no-op there (rect pushing is exercised against the live daemon).
  if (typeof MutationObserver === "function") {
    new MutationObserver(schedule).observe(document.documentElement, {
      subtree: true, childList: true, attributes: true, characterData: true
    });
  }
  if (typeof ResizeObserver === "function") {
    new ResizeObserver(schedule).observe(document.documentElement);
  }
  window.addEventListener("resize", schedule);
  window.addEventListener("scroll", schedule, true);
  window.addEventListener("stackd:frame", schedule);
  document.addEventListener("transitionend", schedule, true);
  document.addEventListener("animationend", schedule, true);
  schedule();
}

function __sdCompileTemplates(root) {
  const SKIP = new Set(["SCRIPT", "STYLE"]);
  const PROBE = /\{\{[\s\S]+?\}\}/;

  // sd-on:click first — BEFORE sd-each detaches its templates, so loop-body
  // elements get their data- markers compiled in while still reachable
  // (the markers then survive cloneNode; live listeners would not).
  const onEls = [];
  const onWalker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let onEl;
  while ((onEl = onWalker.nextNode())) {
    if (SKIP.has(onEl.nodeName)) continue;
    if (onEl.hasAttribute("sd-on:click")) onEls.push(onEl);
  }
  for (const e of onEls) __sdSetupOnClickElement(e);

  // sd-each first — each loop removes its template from the live DOM and
  // replaces it with a comment anchor. Doing this before the text/attr walks
  // keeps those walks from seeing — and per-placeholder-subscribing —
  // anything inside loop bodies (which manage their own subscriptions and
  // need `item`/`index` in scope).
  const eachEls = [];
  const eachWalker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let eachEl;
  while ((eachEl = eachWalker.nextNode())) {
    if (SKIP.has(eachEl.nodeName)) continue;
    if (eachEl.hasAttribute("sd-each")) eachEls.push(eachEl);
  }
  for (const e of eachEls) {
    // Skip elements that were detached by an outer sd-each that already
    // processed them (nested case — warned about in __sdProcessEachElement).
    if (!e.isConnected) continue;
    if (e.hasAttribute("sd-if")) {
      console.warn("[stackd] sd-if on a sd-each element is ignored; filter inside the each expression instead");
      e.removeAttribute("sd-if");
    }
    __sdProcessEachElement(e);
  }

  // sd-if setup pass — installs comment anchors so structure is final before
  // the text/attr walks, but defers initial detachment until those walks have
  // had a chance to compile placeholders inside the subtree.
  const ifJobs = [];
  const ifWalker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let ifEl;
  while ((ifEl = ifWalker.nextNode())) {
    if (SKIP.has(ifEl.nodeName)) continue;
    if (ifEl.hasAttribute("sd-if")) ifJobs.push(ifEl);
  }
  const ifSetups = [];
  for (const e of ifJobs) {
    if (!e.isConnected) continue;
    ifSetups.push(__sdSetupIfElement(e));
  }

  // Collect text nodes first, mutate after — mutating during walk skips siblings.
  const textNodes = [];
  const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
      if (n.parentNode && SKIP.has(n.parentNode.nodeName)) return NodeFilter.FILTER_REJECT;
      return PROBE.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    }
  });
  let t;
  while ((t = tw.nextNode())) textNodes.push(t);
  for (const node of textNodes) __sdProcessTextNode(node);

  // Attributes — same shape, element walker.
  const ew = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let el;
  const attrJobs = [];
  while ((el = ew.nextNode())) {
    if (SKIP.has(el.nodeName)) continue;
    for (const attr of Array.from(el.attributes)) {
      if (PROBE.test(attr.value)) attrJobs.push([el, attr.name, attr.value]);
    }
  }
  for (const [e, name, raw] of attrJobs) __sdProcessAttribute(e, name, raw);

  // sd-if initial eval + dep subscription. Runs last so the subtree's
  // placeholders are compiled (and live-subscribed) before the first
  // detachment.
  for (const { render, deps } of ifSetups) __sdSubscribeAll(deps, render);
}

// Guard against double-compilation if an explicit `import { sd }` in a stack
// races with the auto-injected runtime loader. ES modules dedup by URL so
// the body only runs once anyway — guard is belt-and-suspenders.
//
// Deferred via setTimeout(0) after DOMContentLoaded so any user
// `<script type="module">` body that defines helpers (e.g. `window.icon = …`
// for templates to call) has finished executing before the template walk
// starts. Adds <1ms perceptible delay; eliminates a fragile race.
if (!window.__sd_templates_compiled) {
  window.__sd_templates_compiled = true;
  const compile = () => __sdCompileTemplates(document);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => setTimeout(compile, 0));
  } else {
    setTimeout(compile, 0);
  }
}

// Handshake: tell native we're ready so it can replay buffered state.
try {
  window.webkit.messageHandlers.sd.postMessage({ type: "ready" });
} catch (e) {
  console.error("ready handshake failed", String(e));
}
