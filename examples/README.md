# stackd examples

Each folder is a working stack you can drop into `~/stackd/stacks/` to try.

```sh
cp -r examples/hello ~/stackd/stacks/hello
```

FSEvents picks it up; the panel appears within ~300ms.

| Example | Demonstrates |
|---|---|
| [hello](hello) | Minimal panel — `sd.bind`, two signals, three target shapes |
| [menubar-item](menubar-item) | `sd.menubar.addItem` with a dynamic icon and menu |
| [fs-watcher](fs-watcher) | `sd.fs.watch` + a banged message to other stacks |
| [bang-pair](bang-pair) | Two stacks communicating via `sd.bang` |
| [invocable-palette](invocable-palette) | `invocable: true`, hotkey-summoned overlay, `sd.ax.focused` |

Once you've copied one, `stackd doctor` validates the manifest. `stackd new <name>` scaffolds a fresh `hello`-style stack from the same template.
