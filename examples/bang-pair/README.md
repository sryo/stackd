# bang-pair

Two stacks. **bang-emitter** fires `demo.greeting` every 3 seconds. **bang-handler** declares `"handles": ["demo.greeting"]` in its manifest and runs `window.onBang_demo_greeting` when the bang arrives.

Copy *both* folders into `~/stackd/stacks/`.

Bangs are also fired by the daemon for system events (`sd.window.created`, `sd.window.destroyed`, `sd.window.titlechanged`) and by the CLI (`stackd bang demo.greeting`).
