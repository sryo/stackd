# The template engine

stackd stacks are HTML pages. The template engine binds live daemon state into the DOM declaratively — `{{ }}` placeholders and `sd-*` attributes — with no JavaScript. It walks the document once at load and auto-subscribes the right `sd.*` channels. (Engine: `Runtime/src/90-templates.js`.)

The walk runs once, just after `DOMContentLoaded` and after your `<script type="module">` has executed (so templates can call functions you define). `<script>` and `<style>` contents are never scanned. All subscriptions are torn down on page unload.

## Quick reference

| Feature | Syntax | Scope variables |
|---|---|---|
| Text interpolation | `{{ expr }}` | `sd`, `item`, `index` |
| Attribute binding | `attr="…{{ expr }}…"` | `sd`, `item`, `index` |
| List | `sd-each="arrayExpr"` (+ optional `sd-key="expr"`) | exposes `item`, `index` |
| Conditional | `sd-if="expr"` | `sd` |
| Click | `sd-on:click="expr"` | `sd`, `item`, `index` |
| JS bind | `sd.bind(target, signal\|[signals], fmt?)` | — |
| JS template | `` sd.tpl`…${signal}…` `` | — |

---

## `{{ expression }}` — text interpolation

Put `{{ <JS expression> }}` in **text** or **attribute values**. The contents are full JavaScript evaluated with three identifiers in scope:

- `sd` — the runtime namespace (all channels + helpers).
- `item`, `index` — bound only inside an `sd-each` clone; `undefined` elsewhere.

So property paths, ternaries, operators, methods, optional chaining, and inline calls all work:

```html
<div>{{ sd.battery.percent }}{{ sd.battery.charging ? ' ⚡' : '' }}</div>
<div>{{ sd.windows.focused.title || '(no window title)' }}</div>
<div>{{ sd.location ? sd.location.lat.toFixed(3) + ', ' + sd.location.lon.toFixed(3) : 'waiting for fix…' }}</div>
```

There are **no filters or pipes** — format with plain JS (`.toFixed(1)`, `.padEnd(20)`, ternaries).

**Coercion & safety:** the result is stringified; `null`/`undefined` render as the **empty string**. A parse error logs once and renders empty; a runtime throw is swallowed to empty. Combined with channel defaults (array channels start `[]`, object channels return `undefined` for unknown keys), an expression that reads missing state renders blank rather than breaking the page.

### Auto-subscription

Each placeholder is scanned for known channel paths (`sd.<path>`); every match becomes a dependency, and the placeholder re-evaluates whenever any of those channels push. This is **regex-based on the literal text**, so:

```js
{{ sd.battery.percent }}        // ✓ tracks — "sd.battery" is visible
const b = sd.battery; b.percent // ✗ never re-renders — alias not seen
```

For aliased/dynamic reads, drop to `sd.bind` (below).

---

## `sd-each` — list rendering

Put `sd-each="<arrayExpr>"` on the element to repeat. It's cloned once per item, with `item` and `index` in scope for every `{{ }}` inside (text and attributes):

```html
<li sd-each="sd.usb">{{ item.productName || ('device 0x' + item.productID.toString(16)) }}</li>
<li sd-each="(sd.sensors?.temperatures || []).slice(0, 5)">{{ item.name }} {{ item.value.toFixed(1) }}{{ item.unit }}</li>
```

Filter/slice inline in the expression. If it doesn't return an array, all clones are removed.

### Keys (`sd-key`)

- **Without `sd-key`** (default): full re-render on every push — cheap for short, stable lists.
- **With `sd-key="<expr>"`**: keyed reconciliation. Matching keys **reuse** existing DOM nodes (preserving focus, scroll, animations, IME); missing keys are removed; new keys cloned. Use for large or stateful lists. The key must be a primitive (string/number/boolean) or it falls back to unkeyed with a warning.

### Limitations (v1)

- **Nested `sd-each` is not supported** (inner loop ignored with a warning).
- **`sd-if` on the same element as `sd-each` is ignored** — filter inside the each-expression instead.
- **Per-clone `sd-if` inside an each subtree isn't honored** — use a `{{ cond ? … : '' }}` placeholder for per-item conditionals.

---

## `sd-if` — conditional rendering

`sd-if="<expr>"` attaches the element when the expression is truthy, removes it when falsy (standard JS truthiness). It re-evaluates whenever a referenced channel pushes:

```html
<div sd-if="!sd.usb || sd.usb.length === 0">No USB devices</div>
<div sd-if="!sd.sensors?.temperatures?.length">No temperature sensors</div>
```

There is **no `else` / `sd-else`** — use two sibling `sd-if` elements with complementary conditions. Internal `{{ }}` subscriptions persist across toggles, so a re-attached element already reflects current state.

---

## `sd-on:click` — declarative click handling

`sd-on:click="<expr>"` runs the expression on click, with the same `(sd, item, index)` scope as `{{ }}`:

```html
<button sd-on:click="bump(1)">+1</button>
<button sd-on:click="sd.media.command('toggle')">⏯</button>
```

(`bump` here is a function you defined in a module script.) **`click` is the only event wired today** — there's no generic `sd-on:<event>`.

Stacks are click-through by default; behind this attribute the runtime registers the element's rect with the daemon so the panel becomes clickable exactly over interactive elements (and passes empty areas through). Handlers survive `cloneNode`, so buttons inside `sd-each` work, firing with their own `item`/`index`. Click-handler errors are **logged, not swallowed** (unlike `{{ }}`) — a click you wired is the thing you're debugging.

---

## Attribute binding

There's no separate syntax — put `{{ }}` inside any attribute value (`style`, `class`, `data-*`, `title`, …). Multiple placeholders and literal text concatenate:

```html
<body data-theme="{{ sd.appearance.dark ? 'dark' : 'light' }}">
<div style="--accent: {{ sd.appearance.accentHex || '#0a84ff' }}">
<span class="{{ item.isInUse ? 'live' : '' }}">   <!-- inside an sd-each -->
```

The attribute is rebuilt and re-set on every push.

---

## JS-side sugar: `sd.bind` and `sd.tpl`

For dynamic UI or aliased reads that `{{ }}` can't track, use these from a `<script type="module">`.

### `sd.bind(target, signal, fmt?) → dispose`

Subscribes the signal(s) and writes to a DOM target; repaints on every push; returns a `dispose()` and auto-disposes on unload.

- `signal` may be **one** signal or an **array**; the formatter receives each signal's `.peek()` value as arguments. Passing a namespace/proxy instead of a signal throws a clear `TypeError`.
- `fmt` defaults to identity.

**Target dispatch by shape:**

| Target | Effect |
|---|---|
| `Element` | set `textContent` (null/undefined → `""`) |
| `[el, "html"]` | set `innerHTML` |
| `[el, "value"]` | set `.value` (form inputs) |
| `[el, "data-foo"]` | set `dataset.foo` |
| `[el, "attr.foo"]` | `setAttribute("foo", v)` — `null` value **removes** the attribute |
| `[el, "style.--var"]` | `style.setProperty("--var", v)` |
| `[el, "class.foo"]` | `classList.toggle("foo", !!v)` |

```js
sd.bind(value, sd.battery, b => b ? `${b.percent}% ${b.charging ? "⚡" : ""}` : "…");
sd.bind([document.body, "data-theme"], sd.appearance, a => a?.dark ? "dark" : "light");
sd.bind([dot, "style.--x"], sd.mouse, m => m ? m.x + "px" : "0px");
```

For dynamic UI that churns nodes, hold the returned `dispose` and call it yourself to avoid leaking subscriptions on detached nodes.

### `sd.tpl` — tagged template

Builds DOM with `${...}` interpolations. A `${signal}` is auto-bound via `sd.bind`; other values render as static text. Returns a single `Element` (one root) or a `DocumentFragment` (multi-root):

```js
const row = sd.tpl`<div class="row">${sd.battery} <b>label</b></div>`;
document.body.append(row);
```

### The signal interface

Every `sd.<channel>` is a signal with `.value`, `.subscribe(fn, {interval?})`, `.peek()`, `.first(predicate?)`. `subscribe` fires immediately with the current value and returns an unsub. `{ interval: N }` throttles poll-driven channels (those tagged *poll-tunable* in the [API reference](api.md)); event-driven channels ignore it. See [The reactive model](../concepts/reactive-model.md).

---

## Auto-permission inference

The same `sd.<path>` references the template engine subscribes to also drive **permission inference**: the daemon scans every text asset (HTML/CSS/JS) and auto-adds the implied permission. So `{{ sd.battery }}` grants `battery` with no manifest entry. **Composite** permissions (e.g. `menubar.item`) are never inferred and must be declared. See [Permissions](../concepts/permissions.md).

---

## Gotchas & non-features

- No filters/pipes — format with JS.
- No `else`/`sd-else` — use complementary `sd-if` siblings.
- `sd-on` handles **only `click`**.
- Nested `sd-each`, `sd-if`+`sd-each` on one element, and per-clone `sd-if` are unsupported (warn).
- Aliased channel reads don't track — use `sd.bind`.
- `<script>`/`<style>` content is never scanned.
- `sd.bind` on churned/detached DOM can leak until unload — hold the `dispose`.
- Don't fight the [padding contract / `backdrop-filter` rules](../concepts/chrome-and-material.md) — those are manifest/CSS concerns, not the engine.

## See also

- [The reactive model](../concepts/reactive-model.md) · [`sd.*` API](api.md) · [Manifest reference](manifest.md)
