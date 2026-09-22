#!/bin/bash
# Records the README hero clip and encodes assets/hero.gif + assets/hero.mp4.
#
# How it works (why it is shaped like this is in STORYBOARD.md):
#   - stackd's hot reload is GLOBAL: any change under a daemon's stacks/
#     folder reloads every stack in that daemon. A stage that lives in the
#     same daemon as the widget it edits would be torn down on every save
#     and expose the real desktop for a few frames. So the clip runs on two
#     throwaway daemons, each with its own HOME (own IPC socket, own
#     ~/stackd root), launched via launchd so TCC attributes them to the
#     signed stackd bundle and not to the terminal:
#         stackd.hero.stage  → HOME=$HOMES/stage   hosts hero-stage (level 960)
#         stackd.hero.demo   → HOME=$HOMES/demo    hosts hero-demo  (level 1000)
#     ($HOMES defaults to /tmp/stackd-hero-<time>: unix socket paths are
#     capped at 104 bytes.) The stage writes into
#     $HOMES/demo/stackd/stacks/hero-demo/, the
#     demo daemon's FSEvents watcher reloads the widget — a real hot reload.
#     The user's daemon and ~/stackd/ are never touched.
#   - Recording is `screencapture -v -R` on the centered 1200×676 rect;
#     falls back to cropping a full-screen recording if -R is ignored.
#   - Start sync: the stage's timeline starts on the `hero.start` bang.
#     The clip's t0 is recovered from the video by detecting the first
#     ⌘S toast (bright keycap on the dark editor) — its timeline offset is
#     known from script.js, so the trim is exact regardless of capture
#     start-up latency.
#   - Cleanup runs on EXIT/INT/TERM: both helper daemons are booted out,
#     their plists removed; a detached watchdog boots them out anyway
#     after $WATCHDOG_SECS in case this script is killed with SIGKILL.
#
# Usage:
#   record.sh                  full take + encode
#   record.sh --dry-run        launch, probe, take a still, clean up (no video)
#   record.sh --encode RAW.mov re-encode an existing recording
#
# Env overrides: STACKD_BIN, HERO_RUN_DIR, HERO_HOMES_DIR, HERO_RECORD_SECS, HERO_GIF_WIDTH,
#   HERO_CAPTURE=screencapture|ffmpeg (ffmpeg = avfoundation full-screen + crop).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BIN="${STACKD_BIN:-/Applications/stackd.app/Contents/MacOS/stackd}"
RUN="${HERO_RUN_DIR:-${TMPDIR:-/tmp}/stackd-hero-runs/run-$(date +%Y%m%d-%H%M%S)}"
OUT_GIF="$REPO/assets/hero.gif"
OUT_MP4="$REPO/assets/hero.mp4"
RECORD_SECS="${HERO_RECORD_SECS:-17}"
GIF_WIDTH="${HERO_GIF_WIDTH:-1200}"
CAPTURE="${HERO_CAPTURE:-screencapture}"
PREROLL_SECS=1.5
WATCHDOG_SECS=240
UID_="$(id -u)"

STAGE_LABEL="stackd.hero.stage"
DEMO_LABEL="stackd.hero.demo"
# The helper HOMEs must be SHORT: the IPC socket lives at
# $HOME/Library/Application Support/stackd/daemon.sock and sockaddr_un caps
# the path at 104 bytes — the scratchpad path alone is longer than that.
HOMES="${HERO_HOMES_DIR:-/tmp/stackd-hero-$(date +%H%M%S)}"
STAGE_HOME="$HOMES/stage"
DEMO_HOME="$HOMES/demo"
STAGE_DIR="$STAGE_HOME/stackd/stacks/hero-stage"
DEMO_DIR="$DEMO_HOME/stackd/stacks/hero-demo"
STAGE_PLIST="$RUN/$STAGE_LABEL.plist"
DEMO_PLIST="$RUN/$DEMO_LABEL.plist"

MODE="record"
RAW=""
case "${1:-}" in
  --dry-run) MODE="dry" ;;
  --encode)  MODE="encode"; RAW="${2:?--encode needs a .mov path}" ;;
  "") ;;
  *) echo "usage: record.sh [--dry-run | --encode RAW.mov]" >&2; exit 64 ;;
esac

log()  { printf '[hero] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

# ── cleanup ───────────────────────────────────────────────────────────────

WATCHDOG_PID=""
STAGE_PID=""
DEMO_PID=""
cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  log "cleanup"
  launchctl bootout "gui/$UID_/$DEMO_LABEL"  >/dev/null 2>&1
  launchctl bootout "gui/$UID_/$STAGE_LABEL" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$UID_/$DEMO_LABEL"  >/dev/null 2>&1 || \
    launchctl print "gui/$UID_/$STAGE_LABEL" >/dev/null 2>&1 || break
    sleep 0.3
  done
  # Belt and braces: the helper pids we launched must be gone.
  for p in $DEMO_PID $STAGE_PID; do
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  done
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
  rm -f "$STAGE_PLIST" "$DEMO_PLIST"
  [ -d "$HOMES" ] && rm -rf "$HOMES"
  if [ -f "$RUN/pre-list.txt" ]; then
    "$BIN" list > "$RUN/post-list.txt" 2>&1 || true
    if cmp -s "$RUN/pre-list.txt" "$RUN/post-list.txt"; then
      log "user daemon untouched ($(wc -l < "$RUN/pre-list.txt" | tr -d ' ') stacks, same as before)"
    else
      log "WARNING: user daemon stack list changed during the run:"; diff "$RUN/pre-list.txt" "$RUN/post-list.txt" >&2 || true
    fi
  fi
  exit $rc
}

# ── encode (also used by --encode) ────────────────────────────────────────

encode() {
  local raw="$1" geom="$2"
  local sched; sched="$(node "$HERE/gen.mjs" schedule)"
  local total_ms save1_ms
  total_ms="$(node -pe "JSON.parse(process.argv[1]).total" "$sched")"
  save1_ms="$(node -pe "JSON.parse(process.argv[1]).saves[0].at" "$sched")"

  local vw vh
  read -r vw vh < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$raw" | tr ',' ' ')
  log "raw video ${vw}x${vh}"
  local screenW captureX captureY
  screenW="$(node -pe "JSON.parse(process.argv[1]).screenW" "$geom")"
  captureX="$(node -pe "JSON.parse(process.argv[1]).captureX" "$geom")"
  captureY="$(node -pe "JSON.parse(process.argv[1]).captureY" "$geom")"

  # Region capture → the width is 1200×k. Anything else is a full-screen
  # recording that needs cropping to the rect first.
  local vf="scale=1200:676:flags=lanczos"
  if [ "$vw" != "1200" ] && [ "$vw" != "2400" ]; then
    local s; s="$(node -pe "$vw / $screenW")"
    vf="crop=$(node -pe "Math.round(1200*$s)"):$(node -pe "Math.round(676*$s)"):$(node -pe "Math.round($captureX*$s)"):$(node -pe "Math.round($captureY*$s)"),$vf"
    log "full-screen recording detected → cropping (scale $s)"
  fi
  ffmpeg -v error -y -i "$raw" -vf "$vf" -c:v libx264 -preset fast -crf 10 -pix_fmt yuv444p -an "$RUN/norm.mov"

  # Find t0: first frame where the ⌘S "S" keycap region lights up.
  ffmpeg -v error -y -i "$RUN/norm.mov" \
    -vf "crop=40:30:632:530,signalstats,metadata=print:file=$RUN/toast-stats.txt" -f null - >/dev/null 2>&1
  local toast_t
  toast_t="$(awk '/pts_time:/ { split($0,a,"pts_time:"); t=a[2]+0 } /lavfi.signalstats.YAVG=/ { split($0,b,"="); if (b[2]+0 > 100) { print t; exit } }' "$RUN/toast-stats.txt")"
  [ -n "$toast_t" ] || fail "could not find the ⌘S toast in the recording (stage not visible? see $RUN/toast-stats.txt)"
  local t0; t0="$(node -pe "Math.max(0, $toast_t - $save1_ms/1000).toFixed(3)")"
  local dur; dur="$(node -pe "($total_ms/1000).toFixed(3)")"
  log "toast at ${toast_t}s → t0=${t0}s, clip length ${dur}s"

  ffmpeg -v error -y -ss "$t0" -t "$dur" -i "$RUN/norm.mov" -c:v libx264 -preset fast -crf 10 -pix_fmt yuv444p -an "$RUN/clip.mov"

  # MP4 for the site / social posts.
  ffmpeg -v error -y -i "$RUN/clip.mov" -vf "fps=30,format=yuv420p" \
    -c:v libx264 -preset slow -crf 20 -movflags +faststart -an "$OUT_MP4"
  log "mp4 → $OUT_MP4 ($(du -h "$OUT_MP4" | cut -f1))"

  # GIF: two-pass palette. Tiers go from best to cheapest (width, fps);
  # inside a tier the variants are in preference order and the first one
  # under the 6 MB target wins. Hard cap 10 MB.
  local target=$((6 * 1024 * 1024)) cap=$((10 * 1024 * 1024))
  local chosen="" smallest="" smallest_size=999999999
  for tier in "$GIF_WIDTH 20" "$GIF_WIDTH 15" "1000 15"; do
    set -- $tier; local width="$1" fps="$2"
    for variant in "diff sierra2_4a" "full sierra2_4a" "diff bayer:bayer_scale=4" "full bayer:bayer_scale=4"; do
      set -- $variant; local stats="$1" dither="$2"
      local tag="w${width}-f${fps}-${stats}-${dither%%:*}"
      local pal="$RUN/pal-$tag.png" gif="$RUN/hero-$tag.gif"
      ffmpeg -v error -y -i "$RUN/clip.mov" \
        -vf "fps=$fps,scale=$width:-1:flags=lanczos,palettegen=stats_mode=$stats:max_colors=256:reserve_transparent=0" "$pal"
      ffmpeg -v error -y -i "$RUN/clip.mov" -i "$pal" \
        -lavfi "fps=$fps,scale=$width:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=$dither:diff_mode=rectangle" \
        -loop 0 "$gif"
      local size; size="$(stat -f %z "$gif")"
      log "gif $tag → $((size / 1024)) KB"
      if [ "$size" -lt "$smallest_size" ]; then smallest="$gif"; smallest_size="$size"; fi
      if [ -z "$chosen" ] && [ "$size" -le "$target" ]; then chosen="$gif"; fi
    done
    [ -n "$chosen" ] && break
  done
  if [ -z "$chosen" ]; then
    [ "$smallest_size" -le "$cap" ] || fail "every GIF variant exceeds 10 MB (smallest $smallest_size bytes)"
    log "no variant under 6 MB — using the smallest"
    chosen="$smallest"
  fi
  cp "$chosen" "$OUT_GIF"
  log "gif → $OUT_GIF ($(du -h "$OUT_GIF" | cut -f1)) from $(basename "$chosen")"
  log "intermediates in $RUN"
}

# ── helpers ───────────────────────────────────────────────────────────────

write_plist() {
  local path="$1" label="$2" home="$3" logfile="$4"
  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$home</string>
    <key>STACKD_ROOT</key><string>$home/stackd</string>
  </dict>
  <key>WorkingDirectory</key><string>$home</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$logfile</string>
  <key>StandardErrorPath</key><string>$logfile</string>
</dict>
</plist>
EOF
}

wait_for_stack() {
  local home="$1" id="$2" secs="${3:-15}"
  local n=0
  while [ "$n" -lt $((secs * 4)) ]; do
    if HOME="$home" "$BIN" list 2>/dev/null | grep -qx "$id"; then return 0; fi
    sleep 0.25; n=$((n + 1))
  done
  return 1
}

job_pid() {
  launchctl print "gui/$UID_/$1" 2>/dev/null | awk '/pid = /{print $3; exit}'
}

pixel() { # png x y → "r g b"
  ffmpeg -v error -i "$1" -vf "crop=1:1:$2:$3" -f rawvideo -pix_fmt rgb24 - 2>/dev/null | od -An -tu1 | tr -s ' ' | sed 's/^ //'
}

# Start a video capture of the rect for $2 seconds into $1; runs in the
# background, pid in CAP_PID. screencapture -v -R records just the rect;
# the ffmpeg path records the whole main display (cropped at encode time).
CAP_PID=""
start_capture() {
  local out="$1" secs="$2"
  if [ "$CAPTURE" = "ffmpeg" ]; then
    local dev; dev="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -nE 's/.*\[([0-9]+)\] Capture screen 0.*/\1/p' | head -1)"
    [ -n "$dev" ] || fail "avfoundation: no 'Capture screen 0' device"
    ffmpeg -v error -y -f avfoundation -framerate 30 -capture_cursor 0 -i "${dev}:none" -t "$secs" \
      -c:v libx264 -preset ultrafast -crf 12 -pix_fmt yuv420p "$out" >/dev/null 2>&1 &
  else
    screencapture -x -v -R "$CAP_X,$CAP_Y,$CAP_W,$CAP_H" -V "$secs" "$out" &
  fi
  CAP_PID=$!
}

# ── main ──────────────────────────────────────────────────────────────────

mkdir -p "$RUN"
GEOM_JSON=""
SOCK_SUFFIX="/Library/Application Support/stackd/daemon.sock"
SOCK_LEN=$(( ${#STAGE_HOME} + ${#SOCK_SUFFIX} ))
[ "$SOCK_LEN" -le 100 ] || fail "helper HOME path too long for a unix socket ($SOCK_LEN > 100): set HERO_HOMES_DIR to a short path"

if [ "$MODE" = "encode" ]; then
  swiftc -O -o "$RUN/herotool" "$HERE/herotool.swift" 2>/dev/null || fail "swiftc failed"
  GEOM_JSON="$("$RUN/herotool" geometry)"
  encode "$RAW" "$GEOM_JSON"
  exit 0
fi

trap cleanup EXIT INT TERM

# 1. preflight
for t in ffmpeg ffprobe node swiftc screencapture launchctl; do command -v "$t" >/dev/null || fail "missing tool: $t"; done
[ -x "$BIN" ] || fail "stackd binary not found at $BIN"
"$BIN" list > "$RUN/pre-list.txt" 2>&1 || fail "user daemon not reachable ($BIN list failed)"
log "user daemon ok: $(tr '\n' ' ' < "$RUN/pre-list.txt")"
for label in "$STAGE_LABEL" "$DEMO_LABEL"; do
  if launchctl print "gui/$UID_/$label" >/dev/null 2>&1; then
    log "stale $label job found — booting it out first"
    launchctl bootout "gui/$UID_/$label" >/dev/null 2>&1 || true
    sleep 1
  fi
done
node "$HERE/gen.mjs" check >&2

# 2. geometry
swiftc -O -o "$RUN/herotool" "$HERE/herotool.swift" 2>/dev/null || fail "swiftc failed to build herotool"
GEOM_JSON="$("$RUN/herotool" geometry)"
echo "$GEOM_JSON" > "$RUN/geometry.json"
g() { node -pe "JSON.parse(process.argv[1]).$1" "$GEOM_JSON"; }
SCREEN_W="$(g screenW)"; SCREEN_H="$(g screenH)"; SCALE="$(g scale)"
CAP_X="$(g captureX)"; CAP_Y="$(g captureY)"; CAP_W="$(g captureW)"; CAP_H="$(g captureH)"
MENUBAR_H="$(g menubarH)"; VF_X="$(g vfX)"
log "display ${SCREEN_W}x${SCREEN_H} @${SCALE}x, menubar ${MENUBAR_H}, capture rect ${CAP_X},${CAP_Y} ${CAP_W}x${CAP_H}"
[ "$SCALE" = "1" ] && log "note: display is at 1x — the capture will be 1200x676 px (not retina)"

# Widget position: frame (784,248) → top-left anchor insets relative to visibleFrame.
INSET_Y="$(node -pe "Math.round($CAP_Y + 248 - $MENUBAR_H)")"
INSET_X="$(node -pe "Math.round($CAP_X + 784 - $VF_X)")"

# 3. build both stacks into fresh homes (the helper daemons start after the
#    files exist, so they never see a half-written folder)
node "$HERE/gen.mjs" stage --out "$STAGE_DIR" >&2
node "$HERE/gen.mjs" demo  --out "$DEMO_DIR" --inset-y "$INSET_Y" --inset-x "$INSET_X" >&2
mkdir -p "$STAGE_HOME/Library/Application Support" "$DEMO_HOME/Library/Application Support"
cp -R "$DEMO_DIR" "$RUN/demo-initial"        # reference copy of the frame-1 state
write_plist "$STAGE_PLIST" "$STAGE_LABEL" "$STAGE_HOME" "$RUN/stage.log"
write_plist "$DEMO_PLIST"  "$DEMO_LABEL"  "$DEMO_HOME"  "$RUN/demo.log"

# Detached watchdog: boots the helpers out even if this script is SIGKILLed.
nohup bash -c "sleep $WATCHDOG_SECS; launchctl bootout gui/$UID_/$DEMO_LABEL; launchctl bootout gui/$UID_/$STAGE_LABEL" >/dev/null 2>&1 &
WATCHDOG_PID=$!

# 4. launch: stage first (it hides the desktop), then the widget
launchctl bootstrap "gui/$UID_" "$STAGE_PLIST" || fail "launchctl bootstrap failed for the stage"
wait_for_stack "$STAGE_HOME" "hero-stage" || { cat "$RUN/stage.log" >&2; fail "hero-stage did not load (see $RUN/stage.log)"; }
launchctl bootstrap "gui/$UID_" "$DEMO_PLIST" || fail "launchctl bootstrap failed for the demo"
wait_for_stack "$DEMO_HOME" "hero-demo" || { cat "$RUN/demo.log" >&2; fail "hero-demo did not load (see $RUN/demo.log)"; }
sleep 2
grep -h "bad manifest\|runtime load failed" "$RUN/stage.log" "$RUN/demo.log" 2>/dev/null && fail "helper daemon reported a load error"
if grep -qh "not trusted" "$RUN/stage.log" "$RUN/demo.log" 2>/dev/null; then
  log "WARNING: a helper daemon is not Accessibility-trusted — a system prompt may be on screen. Dismiss it; the clip does not need AX."
fi
STAGE_PID="$(job_pid "$STAGE_LABEL")"; DEMO_PID="$(job_pid "$DEMO_LABEL")"
log "stage pid $STAGE_PID windows: $("$RUN/herotool" windows "$STAGE_PID")"
log "demo  pid $DEMO_PID windows: $("$RUN/herotool" windows "$DEMO_PID")"
"$RUN/herotool" windows "$DEMO_PID" | grep -q '"layer":1000' || log "WARNING: no level-1000 window for the demo yet"

# 5. park the cursor below the capture rect, away from edges and hot corners
"$RUN/herotool" warp "$((SCREEN_W - 60))" "$((CAP_Y + CAP_H + 80))"
sleep 2

# 6. still-frame probe: is the stage actually visible to the capture pipeline?
screencapture -x -R "$CAP_X,$CAP_Y,$CAP_W,$CAP_H" "$RUN/preflight.png"
STILL_W="$(ffprobe -v error -show_entries stream=width -of csv=p=0 "$RUN/preflight.png")"
PS="$(node -pe "$STILL_W / 1200")"
P1="$(pixel "$RUN/preflight.png" "$(node -pe "Math.round(600*$PS)")" "$(node -pe "Math.round(120*$PS)")")"   # editor chrome → ~30 30 30
P2="$(pixel "$RUN/preflight.png" "$(node -pe "Math.round(1150*$PS)")" "$(node -pe "Math.round(30*$PS)")")"   # backdrop, blue zone
log "probe: editor chrome = ($P1) expected ~(30 30 30); backdrop = ($P2) expected blue-ish"
set -- $P1
if [ "${1:-0}" -gt 46 ] || [ "${1:-0}" -lt 16 ] || [ "${3:-0}" -gt 46 ]; then
  fail "stage is not visible in the capture. Screen Recording permission for the app running this script? (System Settings → Privacy & Security → Screen Recording). Still: $RUN/preflight.png"
fi
log "preflight still → $RUN/preflight.png"

if [ "$MODE" = "dry" ]; then
  log "dry run: 2s test capture with $CAPTURE"
  start_capture "$RUN/capture-test.mov" 2
  wait "$CAP_PID" || true
  if [ -s "$RUN/capture-test.mov" ]; then
    log "test capture ok: $(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$RUN/capture-test.mov") → $RUN/capture-test.mov"
  else
    log "WARNING: test capture produced nothing — try HERO_CAPTURE=ffmpeg"
  fi
  log "dry run complete — leaving the stage up for 4s so it can be eyeballed"
  sleep 4
  exit 0
fi

# 7. record, then fire the start bang once the capture is rolling
RAW="$RUN/raw.mov"
start_capture "$RAW" "$RECORD_SECS"
SC_PID="$CAP_PID"
sleep "$PREROLL_SECS"
FIRED="$(HOME="$STAGE_HOME" "$BIN" bang hero.start "dir=$DEMO_DIR")"
log "$FIRED"
echo "$FIRED" | grep -q "to 1 stack" || { kill "$SC_PID" 2>/dev/null; fail "hero.start reached no stack"; }
wait "$SC_PID" || fail "screencapture failed"
[ -s "$RAW" ] || fail "no recording produced"
log "recorded $RAW ($(du -h "$RAW" | cut -f1))"

# Sanity: the demo files on disk must be the second-save contents.
node --input-type=module -e '
  import { expectedWrites } from "'"$HERE"'/stage/script.js";
  import { readFileSync } from "node:fs";
  const w = expectedWrites();
  let ok = true;
  for (const x of w) {
    const disk = readFileSync("'"$DEMO_DIR"'/" + x.file, "utf8");
    if (disk !== x.contents) { ok = false; console.error("MISMATCH on disk:", x.file); }
  }
  console.error(ok ? "[hero] on-disk demo files match the editor buffers byte-for-byte" : "[hero] WARNING: disk/editor mismatch");
'
cp -R "$DEMO_DIR" "$RUN/demo-final"
log "stage wrote $(grep -c "hero\] wrote" "$RUN/stage.log" 2>/dev/null || echo 0) file(s); demo daemon reloaded $(grep -c "file change" "$RUN/demo.log" 2>/dev/null || echo 0) time(s) (expect 2 and 2)"

# 8. tear the helpers down before the slow encode so the screen is free
launchctl bootout "gui/$UID_/$DEMO_LABEL"  >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_/$STAGE_LABEL" >/dev/null 2>&1 || true

# 9. encode
encode "$RAW" "$GEOM_JSON"
