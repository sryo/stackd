#!/usr/bin/env node
// Generates the hero stacks from the single timeline source (stage/script.js)
// so the demo's frame-1 files are byte-identical to the editor's initial
// buffers, and record.sh can read the schedule.
//
//   node gen.mjs check                       verify demo/ matches script.js
//   node gen.mjs schedule                    print {total, saves, toastMs}
//   node gen.mjs demo  --out DIR [--inset-y N --inset-x N]
//   node gen.mjs stage --out DIR
//
// `demo` without insets writes the committed defaults (this machine at
// 2560×1664, menubar 57); record.sh always passes measured values.

import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { FILES, FILE_ORDER, TOAST_MS, serialize, buildSchedule, expectedWrites } from "./stage/script.js";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const cmd = args.shift();
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};

const DEMO_SIZE = { w: 320, h: 180 };
// Capture-frame position of the widget (must match .mock in stage/index.css).
export const DEMO_FRAME_POS = { x: 784, y: 248 };

function demoManifest(insetY, insetX) {
  return {
    id: "hero-demo",
    name: "Hero clip widget",
    anchor: { edge: "top-left", inset: [insetY, insetX] },
    size: DEMO_SIZE,
    material: "glass",
    cornerRadius: 24,
    level: "tooltip",
    display: "primary",
    clickThrough: true,
    hideDuringScreenshot: false,
    permissions: ["battery"],
  };
}

function writeDemo(out, insetY, insetX) {
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "stack.json"), JSON.stringify(demoManifest(insetY, insetX), null, 2) + "\n");
  for (const f of FILE_ORDER) writeFileSync(join(out, f), serialize(FILES[f]));
}

function writeStage(out) {
  mkdirSync(out, { recursive: true });
  for (const f of ["stack.json", "index.html", "index.css", "script.js", "stage.js"]) {
    copyFileSync(join(here, "stage", f), join(out, f));
  }
}

switch (cmd) {
  case "check": {
    let ok = true;
    for (const f of FILE_ORDER) {
      const disk = readFileSync(join(here, "demo", f), "utf8");
      const want = serialize(FILES[f]);
      if (disk !== want) { ok = false; console.error(`demo/${f} differs from script.js FILES`); }
    }
    const longest = Math.max(...FILE_ORDER.flatMap((f) => FILES[f].map((l) => l.length)));
    const writes = expectedWrites();
    const longestWritten = Math.max(...writes.flatMap((w) => w.contents.split("\n").map((l) => l.length)));
    console.log(`lines ≤ 40 chars: ${Math.max(longest, longestWritten) <= 40 ? "yes" : "NO"} (max ${Math.max(longest, longestWritten)})`);
    console.log(`saves: ${writes.map((w) => `${w.file}@${w.at}ms`).join(", ")}`);
    if (!ok) process.exit(1);
    console.log("demo/ matches script.js");
    break;
  }
  case "schedule": {
    const s = buildSchedule();
    console.log(JSON.stringify({ total: s.total, saves: s.saves, toastMs: TOAST_MS }));
    break;
  }
  case "demo": {
    const out = opt("--out", join(here, "demo"));
    const insetY = Number(opt("--inset-y", 685));
    const insetX = Number(opt("--inset-x", 1464));
    writeDemo(out, insetY, insetX);
    console.log(`wrote demo stack → ${out} (inset y=${insetY} x=${insetX})`);
    break;
  }
  case "stage": {
    const out = opt("--out");
    if (!out) { console.error("stage needs --out DIR"); process.exit(64); }
    writeStage(out);
    console.log(`wrote stage stack → ${out}`);
    break;
  }
  default:
    console.error("usage: gen.mjs check | schedule | demo --out DIR [--inset-y N --inset-x N] | stage --out DIR");
    process.exit(64);
}
