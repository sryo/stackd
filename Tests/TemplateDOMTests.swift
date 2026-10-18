import Foundation
import AppKit
import WebKit

// Characterization tests for the template engine's DOM-coupled paths in
// `Runtime/src/90-templates.js`: `__sdProcessTextNode`,
// `__sdProcessAttribute`, `sd-each` (unkeyed and keyed), `sd-if`, and the
// pass order inside `__sdCompileTemplates`. They run the generated
// Runtime/api.js in a real WKWebView, because those paths walk and mutate
// live DOM that JSHarness's JSContext shim doesn't have.
//
// Each test mounts its fixture into a fresh container, compiles it with
// `__sdCompileTemplates(container)`, drives channels through the same
// `window.__sd_push` the daemon calls, and reads the DOM back — all inside
// one synchronous script, since signal subscribers run synchronously.

private final class SilentMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {}
}

/// A page holding the runtime the way a stack sees it: the channel table
/// at document start, then api.js (as a classic script, so its top-level
/// `__sd*` functions are reachable from evaluateJavaScript) at document end.
private struct TemplatePage {
    let webView: WKWebView

    init() throws {
        let source = try String(contentsOfFile: "Runtime/api.js", encoding: .utf8)
            .replacingOccurrences(of: "export const sd = ", with: "const sd = ")
        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.add(SilentMessageHandler(), name: "sd")
        ucc.addUserScript(WKUserScript(source: "window.__sd_channels = \(Channels.jsBootstrapJSON);",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        // The probe resolves once the runtime's own document-level compile
        // has run, so a test's fixture is never compiled twice.
        webView.loadHTMLString("<body><i id=\"probe\">{{ 1 + 1 }}</i></body>", baseURL: nil)
        var ready = false
        spin(timeout: 10) {
            ready = (evalSync("document.getElementById('probe') && document.getElementById('probe').textContent") as? String) == "2"
            return ready
        }
        try expect(ready, "runtime never compiled the probe")
    }

    private func evalSync(_ script: String) -> Any? {
        var out: Any?
        var done = false
        webView.evaluateJavaScript(script) { v, _ in out = v; done = true }
        spin(timeout: 10) { done }
        return out
    }

    /// Runs `body` as a function body with the fixture helpers in scope and
    /// returns its (string) result.
    func run(_ body: String) -> String? {
        let script = """
        (function () {
          function build(html) {
            const root = document.createElement('div');
            root.innerHTML = html;
            document.body.appendChild(root);
            return root;
          }
          function mount(html) {
            const root = build(html);
            __sdCompileTemplates(root);
            return root;
          }
          function push(name, value) { window.__sd_push(name, value); }
          \(body)
        })()
        """
        return evalSync(script) as? String
    }
}

func registerTemplateDOMTests() {
    // ── __sdProcessTextNode ───────────────────────────────────────────────

    test("template DOM: a text placeholder becomes a span between its literal text") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<p>a {{ sd.battery.percent }} b {{ sd.battery.charging ? "yes" : "no" }} c</p>');
        const before = r.innerHTML;
        push('battery', { percent: 42, charging: true });
        return before + '|' + r.innerHTML;
        """)
        try expectEqual(got, "<p>a <span></span> b <span>no</span> c</p>|<p>a <span>42</span> b <span>yes</span> c</p>")
    }

    test("template DOM: adjacent placeholders leave no empty text nodes") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<p>{{ 1 }}{{ "x" }}</p>');
        return r.innerHTML + '|' + r.firstChild.childNodes.length;
        """)
        try expectEqual(got, "<p><span>1</span><span>x</span></p>|2")
    }

    test("template DOM: null, undefined and throwing placeholders render empty") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<p>[{{ null }}][{{ undefined }}][{{ nope.deeper }}][{{ 0 }}]</p>');
        return r.innerHTML;
        """)
        try expectEqual(got, "<p>[<span></span>][<span></span>][<span></span>][<span>0</span>]</p>")
    }

    test("template DOM: text without placeholders keeps its node; script and style text is skipped") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<p>plain</p><style>/* {{ 1 }} */</style><script type="text/x-none">{{ 2 }}</script>');
        const plain = r.querySelector('p').firstChild;
        const kept = plain.nodeType === 3 && plain.nodeValue === 'plain';
        return kept + '|' + r.querySelector('style').textContent + '|' + r.querySelector('script').textContent;
        """)
        try expectEqual(got, "true|/* {{ 1 }} */|{{ 2 }}")
    }

    test("template DOM: a text placeholder re-renders only when one of its channels pushes") {
        let page = try TemplatePage()
        let got = page.run("""
        window.__evals = 0;
        mount('<p>{{ (window.__evals++, sd.battery.percent) }}</p>');
        const afterMount = window.__evals;
        push('sensors', { fans: [{ name: 'x' }] });
        const afterOther = window.__evals;
        push('battery', { percent: 1 });
        return [afterOther - afterMount, window.__evals - afterOther].join(',');
        """)
        try expectEqual(got, "0,1")
    }

    // ── __sdProcessAttribute ──────────────────────────────────────────────

    test("template DOM: attribute placeholders concatenate with their literals and re-render on push") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<div class="a {{ sd.battery.percent }} b" title="{{ sd.battery.percent }}%{{ sd.battery.charging ? \\'+\\' : \\'\\' }}" data-x="plain"></div>');
        const d = r.firstChild;
        const before = [d.getAttribute('class'), d.getAttribute('title'), d.getAttribute('data-x')].join('/');
        push('battery', { percent: 7, charging: true });
        const after = [d.getAttribute('class'), d.getAttribute('title'), d.getAttribute('data-x')].join('/');
        return before + '|' + after;
        """)
        try expectEqual(got, "a  b/%/plain|a 7 b/7%+/plain")
    }

    test("template DOM: an attribute placeholder re-renders only for its own channels") {
        let page = try TemplatePage()
        let got = page.run("""
        window.__evals = 0;
        const r = mount('<div title="{{ (window.__evals++, sd.battery.percent) }}"></div>');
        const afterMount = window.__evals;
        push('sensors', { fans: [{ name: 'x' }] });
        const afterOther = window.__evals;
        push('battery', { percent: 9 });
        return [afterOther - afterMount, window.__evals - afterOther, r.firstChild.getAttribute('title')].join(',');
        """)
        try expectEqual(got, "0,1,9")
    }

    // ── sd-each, unkeyed ──────────────────────────────────────────────────

    test("template DOM: unkeyed sd-each replaces its element with an anchor and renders the items in array order") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans" class="{{ item.kind }}">{{ item.name }}#{{ index }}</li></ul>');
        const ul = r.firstChild;
        const empty = ul.innerHTML;
        push('sensors', { fans: [{ name: 'a', kind: 'x' }, { name: 'b', kind: 'y' }, { name: 'c', kind: 'z' }] });
        return empty + '|' + ul.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-each:sd.sensors.fans -->|<!-- sd-each:sd.sensors.fans --><li class=\"x\">a#0</li><li class=\"y\">b#1</li><li class=\"z\">c#2</li>")
    }

    test("template DOM: unkeyed sd-each re-creates every clone on each push") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans">{{ item.name }}</li></ul>');
        push('sensors', { fans: [{ name: 'a' }, { name: 'b' }] });
        const first = Array.from(r.querySelectorAll('li'));
        push('sensors', { fans: [{ name: 'a' }, { name: 'b' }] });
        const second = Array.from(r.querySelectorAll('li'));
        return second.length + '|' + second.some(n => first.includes(n));
        """)
        try expectEqual(got, "2|false")
    }

    test("template DOM: sd-each over a non-array clears its clones") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.battery.list">{{ item }}</li></ul>');
        push('battery', { list: ['a', 'b'] });
        const two = r.querySelectorAll('li').length;
        push('battery', { list: null });
        return two + '|' + r.firstChild.innerHTML;
        """)
        try expectEqual(got, "2|<!-- sd-each:sd.battery.list -->")
    }

    test("template DOM: sd-each over a bare array signal renders its current items") {
        // The documented form: `sd-each="sd.usb"` / `sd-each="sd.camera"`
        // iterate the signal's payload, exactly like `.value`.
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.usb">{{ item.name }}#{{ index }}</li></ul><ol><li sd-each="sd.camera">{{ item.name }}</li></ol><p><b sd-each="sd.usb.value">{{ item.name }}</b></p>');
        push('usb', [{ name: 'a' }, { name: 'b' }]);
        push('camera', [{ name: 'cam' }]);
        const first = [r.querySelector('ul').innerHTML, r.querySelector('ol').innerHTML, r.querySelector('p').innerHTML].join('|');
        push('usb', [{ name: 'c' }]);
        return first + '|' + r.querySelector('ul').innerHTML;
        """)
        try expectEqual(got, "<!-- sd-each:sd.usb --><li>a#0</li><li>b#1</li>|<!-- sd-each:sd.camera --><li>cam</li>|<!-- sd-each:sd.usb.value --><b>a</b><b>b</b>|<!-- sd-each:sd.usb --><li>c#0</li>")
    }

    test("template DOM: keyed sd-each over a bare array signal reconciles by key") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.usb" sd-key="item.id">{{ item.name }}</li></ul>');
        push('usb', [{ id: 1, name: 'a' }, { id: 2, name: 'b' }]);
        const [a, b] = Array.from(r.querySelectorAll('li'));
        push('usb', [{ id: 2, name: 'b' }, { id: 1, name: 'a' }]);
        const now = Array.from(r.querySelectorAll('li'));
        return (now[0] === b) + ',' + (now[1] === a) + ',' + now.map(n => n.textContent).join('');
        """)
        try expectEqual(got, "true,true,ba")
    }

    test("template DOM: sd-each over a signal whose payload is not an array renders nothing") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.battery">{{ item }}</li></ul>');
        push('battery', { percent: 3 });
        return r.firstChild.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-each:sd.battery -->")
    }

    // ── sd-each, keyed ────────────────────────────────────────────────────

    test("template DOM: keyed sd-each renders in array order") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans" sd-key="item.id">{{ item.name }}#{{ index }}</li></ul>');
        push('sensors', { fans: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }, { id: 3, name: 'c' }] });
        return r.firstChild.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-each:sd.sensors.fans --><li>a#0</li><li>b#1</li><li>c#2</li>")
    }

    test("template DOM: keyed sd-each keeps node identity across a reorder and re-applies slots") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans" sd-key="item.id" data-i="{{ index }}">{{ item.name }}</li></ul>');
        push('sensors', { fans: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }, { id: 3, name: 'c' }] });
        const byKey = {};
        for (const li of r.querySelectorAll('li')) byKey[li.textContent] = li;
        push('sensors', { fans: [{ id: 3, name: 'c' }, { id: 1, name: 'a' }, { id: 2, name: 'b' }] });
        const now = Array.from(r.querySelectorAll('li'));
        const same = now[0] === byKey.c && now[1] === byKey.a && now[2] === byKey.b;
        const scope = now.map(n => n.__sdScope.index + ':' + n.__sdScope.item.name).join(' ');
        return same + '|' + r.firstChild.innerHTML + '|' + scope;
        """)
        try expectEqual(got, "true|<!-- sd-each:sd.sensors.fans --><li data-i=\"0\">c</li><li data-i=\"1\">a</li><li data-i=\"2\">b</li>|0:c 1:a 2:b")
    }

    test("template DOM: keyed sd-each inserts a new key in place and keeps the existing nodes") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans" sd-key="item.id">{{ item.name }}</li></ul>');
        push('sensors', { fans: [{ id: 1, name: 'a' }, { id: 3, name: 'c' }] });
        const [a, c] = Array.from(r.querySelectorAll('li'));
        push('sensors', { fans: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }, { id: 3, name: 'c' }] });
        const now = Array.from(r.querySelectorAll('li'));
        return (now[0] === a) + ',' + (now[2] === c) + ',' + now.map(n => n.textContent).join('');
        """)
        try expectEqual(got, "true,true,abc")
    }

    test("template DOM: keyed sd-each removes a dropped key and keeps the rest") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans" sd-key="item.id">{{ item.name }}</li></ul>');
        push('sensors', { fans: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }, { id: 3, name: 'c' }] });
        const [a, b, c] = Array.from(r.querySelectorAll('li'));
        push('sensors', { fans: [{ id: 1, name: 'a' }, { id: 3, name: 'c' }] });
        const now = Array.from(r.querySelectorAll('li'));
        return [now.length, now[0] === a, now[1] === c, b.isConnected].join(',');
        """)
        try expectEqual(got, "2,true,true,false")
    }

    test("template DOM: a non-primitive sd-key falls back to the unkeyed render") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans" sd-key="item">{{ item.name }}</li></ul>');
        push('sensors', { fans: [{ name: 'a' }, { name: 'b' }] });
        const first = Array.from(r.querySelectorAll('li'));
        push('sensors', { fans: [{ name: 'a' }, { name: 'b' }] });
        const second = Array.from(r.querySelectorAll('li'));
        return second.map(n => n.textContent).join('') + '|' + second.some(n => first.includes(n));
        """)
        try expectEqual(got, "ab|false")
    }

    // ── sd-if ─────────────────────────────────────────────────────────────

    test("template DOM: sd-if detaches when falsy and re-attaches after its anchor when truthy") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = build('<p>x</p><b sd-if="sd.battery.charging">on</b><p>y</p>');
        const b = r.querySelector('b');
        __sdCompileTemplates(r);
        const off = r.innerHTML;
        push('battery', { charging: true });
        const on = r.innerHTML;
        const sameNode = r.querySelector('b') === b;
        push('battery', { charging: false });
        return off + '|' + on + '|' + r.innerHTML + '|' + sameNode;
        """)
        try expectEqual(got, "<p>x</p><!-- sd-if:sd.battery.charging --><p>y</p>|<p>x</p><!-- sd-if:sd.battery.charging --><b>on</b><p>y</p>|<p>x</p><!-- sd-if:sd.battery.charging --><p>y</p>|true")
    }

    test("template DOM: a falsy-at-load sd-if subtree still has its placeholders wired") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<div sd-if="sd.battery.charging" title="{{ sd.battery.percent }}">{{ sd.battery.percent }}%</div>');
        push('battery', { charging: false, percent: 5 });
        push('battery', { charging: true, percent: 6 });
        return r.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-if:sd.battery.charging --><div title=\"6\"><span>6</span>%</div>")
    }

    test("template DOM: a throwing sd-if expression counts as falsy") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<b sd-if="nope.deeper">x</b>');
        return r.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-if:nope.deeper -->")
    }

    // ── __sdCompileTemplates pass order ───────────────────────────────────

    test("template DOM: loop bodies get item scope, not document-level placeholder spans") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans">{{ item.name }}</li></ul>');
        push('sensors', { fans: [{ name: 'a' }] });
        return r.firstChild.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-each:sd.sensors.fans --><li>a</li>")
    }

    test("template DOM: sd-on:click inside a loop body is compiled before the loop clones it") {
        let page = try TemplatePage()
        let got = page.run("""
        window.__clicked = [];
        window.__rec = (v) => window.__clicked.push(v);
        const r = mount('<ul><li sd-each="sd.sensors.fans" sd-key="item.id"><button sd-on:click="__rec(item.name + index)">{{ item.name }}</button></li></ul>');
        push('sensors', { fans: [{ id: 1, name: 'a' }, { id: 2, name: 'b' }] });
        const buttons = Array.from(r.querySelectorAll('button'));
        const marked = buttons.every(b => b.hasAttribute('data-sd-on-click') && !b.hasAttribute('sd-on:click'));
        for (const b of buttons) b.click();
        return marked + '|' + window.__clicked.join(',');
        """)
        try expectEqual(got, "true|a0,b1")
    }

    test("template DOM: sd-if on an sd-each element is dropped and the loop still renders") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<ul><li sd-each="sd.sensors.fans" sd-if="false">{{ item.name }}</li></ul>');
        push('sensors', { fans: [{ name: 'a' }] });
        return r.firstChild.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-each:sd.sensors.fans --><li>a</li>")
    }

    test("template DOM: an sd-each nested in another loop's body is left as a literal attribute") {
        let page = try TemplatePage()
        let got = page.run("""
        const r = mount('<div sd-each="sd.sensors.fans"><i sd-each="item.parts">p</i>{{ item.name }}</div>');
        push('sensors', { fans: [{ name: 'a', parts: [1, 2] }] });
        return r.innerHTML;
        """)
        try expectEqual(got, "<!-- sd-each:sd.sensors.fans --><div><i sd-each=\"item.parts\">p</i>a</div>")
    }

    test("template DOM: sd-if placeholders compile while attached, then the first eval detaches") {
        // The text and attribute walks run between sd-if setup and its first
        // render, so a hidden subtree's `{{ }}` is already a live span.
        let page = try TemplatePage()
        let got = page.run("""
        const r = build('<p sd-if="false" title="{{ 2 + 2 }}">{{ 1 + 2 }}</p>');
        const p = r.firstChild;
        __sdCompileTemplates(r);
        return p.isConnected + '|' + p.outerHTML + '|' + r.innerHTML;
        """)
        try expectEqual(got, "false|<p title=\"4\"><span>3</span></p>|<!-- sd-if:false -->")
    }
}
