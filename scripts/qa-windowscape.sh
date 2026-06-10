#!/usr/bin/env bash
# qa-windowscape.sh — end-to-end QA harness for windowscape tiling +
# overlay-border focused-window outline. Hammerspoon-free (user direction,
# 2026-06-09).
#
# Oracle: CGWindowList via JXA (scripts/qa-windowscape/cgwindows.js) reads
# real window state — owner, bounds, layer, z-order — independently of
# stackd's own channels, with no TCC prompt. Minimized windows drop out of
# the on-screen list, which is exactly the signal S3/S6 need.
#
# Driver: AppleScript on TextEdit via osascript (open / close / minimize /
# restore / resize / raise). Requires ONE Automation grant: your terminal →
# TextEdit (macOS prompts on first run; click Allow). TextEdit's AppleScript
# `id of window` is the NSWindow windowNumber == CGWindowID, so driver ids
# and oracle ids share one id space.
#
# Test subject: TextEdit windows opened from saved temp files
# (/tmp/qa-windowscape/qa-ws-N.txt) — saved docs close without a prompt and
# titles carry the qa-ws- marker so cleanup can never touch user windows.
# Second app for S5: Calculator (launched with `open`, killed afterward only
# if the harness started it — no Apple Events, no extra TCC).
#
# Scenarios (exit code = number of failures):
#   S1 open x3, S2 close middle, S3 minimize/restore, S4 pairwise resize,
#   S5 outline focus-cycle, S6 rapid churn.
#
# Re-runnable and idempotent: an EXIT trap closes every window the harness
# spawned (and stragglers from a previous run, found by title marker).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_DIR="$REPO_ROOT/scripts/qa-windowscape"
CGJS="$QA_DIR/cgwindows.js"
REPORT_FILE="$QA_DIR/last-run.txt"
TMP_FILES="/tmp/qa-windowscape"
MARKER="qa-ws-"
STACKD_BIN="$REPO_ROOT/.build/stackd"

FAILS=0
REPORT_LINES=()
EXCL="com.apple.loginwindow"
CALC_LAUNCHED=0

# ---- plumbing ---------------------------------------------------------------

oracle() { osascript -l JavaScript "$CGJS" "$@" 2>&1; }

excl_json() { printf '{"excluded":"%s"}' "$EXCL"; }

te() { osascript -e "tell application \"TextEdit\" to $1" 2>&1; }

say() { printf '%s\n' "$*"; }

record() { # record "S1 open" "PASS" "detail"
  local line
  line=$(printf '%-22s %-4s %s' "$1" "$2" "$3")
  REPORT_LINES+=("$line")
  say "$line"
  [ "$2" = "FAIL" ] && FAILS=$((FAILS + 1))
}

die() { say "PREFLIGHT FAIL: $*"; exit 99; }

cleanup() {
  osascript -e "tell application \"TextEdit\" to close (every window whose name begins with \"$MARKER\")" >/dev/null 2>&1
  [ "$CALC_LAUNCHED" = "1" ] && killall Calculator >/dev/null 2>&1
  rm -rf "$TMP_FILES"
}
trap cleanup EXIT

# ---- window driver (AppleScript on TextEdit) ---------------------------------

OPENED_ID=""
open_qa_window() { # open_qa_window <n>  → sets OPENED_ID (CGWindowID)
  local n="$1" f id i
  f="$TMP_FILES/${MARKER}${n}.txt"
  printf 'qa window %s\n' "$n" > "$f"
  open -a TextEdit "$f" || return 1
  OPENED_ID=""
  for i in $(seq 1 20); do
    id=$(te "get id of window \"${MARKER}${n}.txt\"")
    if [[ "$id" =~ ^[0-9]+$ ]]; then OPENED_ID="$id"; break; fi
    sleep 0.25
  done
  [ -n "$OPENED_ID" ] || return 1
  # If the window opened off the primary display it won't be in the oracle's
  # eligible set — drag it onto primary so the invariants can see it.
  if ! sig_has_id "$(oracle sig "$(excl_json)")" "$OPENED_ID"; then
    osascript -e "tell application \"TextEdit\" to set bounds of window id $OPENED_ID to {100, 100, 900, 800}" >/dev/null 2>&1
    sleep 0.5
  fi
  return 0
}

close_win()  { te "close window id $1" >/dev/null; }
minimize()   { te "set miniaturized of window id $1 to true" >/dev/null; }
unminimize() { te "set miniaturized of window id $1 to false" >/dev/null; }
is_min()     { te "get miniaturized of window id $1"; }

grow_right() { # grow_right <id> <px> — right edge only (x/y/h unchanged)
  osascript >/dev/null 2>&1 \
    -e "tell application \"TextEdit\"" \
    -e "set b to bounds of window id $1" \
    -e "set item 3 of b to (item 3 of b) + $2" \
    -e "set bounds of window id $1 to b" \
    -e "end tell"
}

focus_te() { # raise window in-app, then bring TextEdit frontmost
  te "set index of window id $1 to 1" >/dev/null
  te "activate" >/dev/null
}

win_x() { # leftmost x of window <id> from the oracle's eligible dump
  oracle eligible "$(excl_json)" | tr ' ' '\n' \
    | sed -n "s/^$1=[^[]*\[\(-\{0,1\}[0-9]*\),.*/\1/p"
}

sig_has_id() { # sig_has_id <sig> <id>
  printf '%s' "$1" | grep -qE "(^|\|)${2}:"
}

# ---- invariant pollers ------------------------------------------------------

CONV_DETAIL=""
wait_converged() { # wait_converged <steps>  (250ms each) → 0 on I2-stable
  local steps="$1" i cur prev="" verdict=""
  for i in $(seq 1 "$steps"); do
    cur=$(oracle sig "$(excl_json)")
    if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
      verdict=$(oracle checkI2 "$(excl_json)")
      if [[ "$verdict" == OK* ]]; then
        CONV_DETAIL="converged step=$i ($verdict)"
        return 0
      fi
    fi
    prev="$cur"
    sleep 0.25
  done
  CONV_DETAIL="timeout after ${steps}x250ms: ${verdict:-layout-never-stable}; $(oracle checkI2 "$(excl_json)")"
  return 1
}

wait_stable() { # wait_stable <steps> — frames stop changing (no I2 demand)
  local steps="$1" i cur prev=""
  for i in $(seq 1 "$steps"); do
    cur=$(oracle sig "$(excl_json)")
    if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then return 0; fi
    prev="$cur"
    sleep 0.25
  done
  return 1
}

OUTLINE_DETAIL=""
check_outline() { # check_outline <winId> — I4, polls up to 1.5s
  local tid="$1" i out
  OUTLINE_DETAIL=""
  for i in $(seq 1 6); do
    out=$(oracle outline "{\"targetId\":$tid,\"tol\":16,\"excluded\":\"$EXCL\"}")
    OUTLINE_DETAIL="$out"
    [[ "$out" == OK* ]] && return 0
    sleep 0.25
  done
  return 1
}

# ---- preflight ----------------------------------------------------------------

say "qa-windowscape — preflight"

pgrep -x stackd >/dev/null || die "stackd daemon not running (start: scripts/daemonctl.sh start)"

STACKS=$("$STACKD_BIN" list 2>&1) || die "stackd list failed: $STACKS"
printf '%s' "$STACKS" | grep -qx "windowscape"    || die "windowscape stack not loaded (loaded: $(printf '%s' "$STACKS" | tr '\n' ' '))"
printf '%s' "$STACKS" | grep -qx "overlay-border" || die "overlay-border stack not loaded (loaded: $(printf '%s' "$STACKS" | tr '\n' ' '))"

LANDSCAPE=$(oracle landscape)
case "$LANDSCAPE" in
  true)  : ;;
  false) die "primary display is portrait — harness invariants assume a horizontal row" ;;
  *)     die "CGWindowList oracle not working: $LANDSCAPE" ;;
esac

# Automation grant check — first run pops "Terminal wants to control
# TextEdit"; click Allow. A previous Deny shows error -1743 here.
say "checking TextEdit automation (allow the permission dialog if one appears)..."
TE_OK=$(te "get name")
[ "$TE_OK" = "TextEdit" ] || die "cannot script TextEdit: $TE_OK — grant Automation permission (System Settings > Privacy & Security > Automation)"

# windowscape exclusion list (exclusionMode=true → apps tile unless listed).
RAW_EXCL=$(defaults read com.stackd.stack.windowscape listedApps 2>/dev/null || true)
if [ -n "$RAW_EXCL" ]; then
  PARSED=$(printf '%s\n' "$RAW_EXCL" \
    | sed -n 's/^[[:space:]]*"\{0,1\}\([^"=]*[^"= ]\)"\{0,1\}[[:space:]]*=[[:space:]]*1;$/\1/p' \
    | tr '\n' ',' | sed 's/,$//')
  [ -n "$PARSED" ] && EXCL="$PARSED"
fi
case ",$EXCL," in
  *",TextEdit,"*|*",com.apple.TextEdit,"*)
    die "TextEdit is in windowscape's exclusion list ($EXCL) — pick another tiled app" ;;
esac

TABMODE=$(defaults read -g AppleWindowTabbingMode 2>/dev/null || echo "default")
[ "$TABMODE" = "always" ] && die "AppleWindowTabbingMode=always — TextEdit docs would open as tabs, not windows"

say "preflight ok — excluded apps: $EXCL"

mkdir -p "$TMP_FILES"

# Clean slate: close stragglers from a previous run, let the tiler settle.
osascript -e "tell application \"TextEdit\" to close (every window whose name begins with \"$MARKER\")" >/dev/null 2>&1
sleep 1

say ""
say "scenarios"

WIN_IDS=()

# ---- S1: open windows one at a time up to 3, I2 after each -------------------

S1_STATUS="PASS"; S1_DETAIL=""
for n in 1 2 3; do
  if ! open_qa_window "$n"; then
    S1_STATUS="FAIL"; S1_DETAIL="window $n never appeared (open -a TextEdit)"; break
  fi
  WIN_IDS+=("$OPENED_ID")
  if ! wait_converged 12; then
    S1_STATUS="FAIL"; S1_DETAIL="after opening window $n (id=$OPENED_ID): $CONV_DETAIL"; break
  fi
  S1_DETAIL="3 windows tiled; last: $CONV_DETAIL"
done
record "S1 open" "$S1_STATUS" "$S1_DETAIL"

# ---- S2: close the middle window (by x), I2 within 3s ------------------------

S2_STATUS="SKIP"; S2_DETAIL="needs 3 windows from S1"
if [ "${#WIN_IDS[@]}" -eq 3 ]; then
  MID_ID=$(for id in "${WIN_IDS[@]}"; do echo "$(win_x "$id") $id"; done | sort -n | sed -n 2p | awk '{print $2}')
  close_win "$MID_ID"
  if wait_converged 12; then
    S2_STATUS="PASS"; S2_DETAIL="closed id=$MID_ID; $CONV_DETAIL"
  else
    S2_STATUS="FAIL"; S2_DETAIL="closed id=$MID_ID; $CONV_DETAIL"
  fi
  NEW_IDS=()
  for id in "${WIN_IDS[@]}"; do [ "$id" != "$MID_ID" ] && NEW_IDS+=("$id"); done
  WIN_IDS=(${NEW_IDS[@]+"${NEW_IDS[@]}"})
fi
record "S2 close" "$S2_STATUS" "$S2_DETAIL"

# ---- S3: minimize → peers absorb; restore → regains a slot --------------------

S3_STATUS="SKIP"; S3_DETAIL="no window available"
if [ "${#WIN_IDS[@]}" -ge 1 ]; then
  M_ID="${WIN_IDS[0]}"
  minimize "$M_ID"
  S3_STATUS="PASS"; S3_DETAIL=""
  if wait_converged 12; then
    SIG=$(oracle sig "$(excl_json)")
    if sig_has_id "$SIG" "$M_ID"; then
      S3_STATUS="FAIL"; S3_DETAIL="minimized id=$M_ID still in tiled set"
    fi
  else
    S3_STATUS="FAIL"; S3_DETAIL="after minimize id=$M_ID: $CONV_DETAIL"
  fi
  unminimize "$M_ID"
  if [ "$S3_STATUS" = "PASS" ]; then
    if wait_converged 12; then
      SIG=$(oracle sig "$(excl_json)")
      if sig_has_id "$SIG" "$M_ID"; then
        S3_DETAIL="minimize absorbed + restore re-slotted (id=$M_ID); $CONV_DETAIL"
      else
        S3_STATUS="FAIL"; S3_DETAIL="restored id=$M_ID missing from tiled set (miniaturized=$(is_min "$M_ID"))"
      fi
    else
      S3_STATUS="FAIL"; S3_DETAIL="after restore id=$M_ID: $CONV_DETAIL"
    fi
  else
    wait_stable 12 >/dev/null # still restore so later scenarios have the window
  fi
fi
record "S3 minimize/restore" "$S3_STATUS" "$S3_DETAIL"

# ---- S4: pairwise resize (I3) -------------------------------------------------

S4_STATUS="SKIP"; S4_DETAIL="prereqs missing"
if open_qa_window 4; then
  WIN_IDS+=("$OPENED_ID")
  wait_converged 12 >/dev/null
  # Eligible windows left→right; A = leftmost qa window with a right
  # neighbor, B = that neighbor (any app; we only observe it).
  ORDERED=$(oracle eligible "$(excl_json)" | tr ' ' '\n' | sed -n 's/^\([0-9][0-9]*\)=.*/\1/p')
  A_ID=""; B_ID=""
  PREV=""
  for id in $ORDERED; do
    if [ -n "$PREV" ] && [ -z "$B_ID" ]; then
      for qid in "${WIN_IDS[@]}"; do
        if [ "$PREV" = "$qid" ]; then A_ID="$PREV"; B_ID="$id"; break; fi
      done
    fi
    PREV="$id"
  done
  if [ -z "$A_ID" ]; then
    S4_STATUS="FAIL"; S4_DETAIL="could not pick A/B (order: $ORDERED)"
  else
    PRE_SIG=$(oracle sig "$(excl_json)")
    grow_right "$A_ID" 150
    sleep 1 # drift watcher tick (500ms) + retile
    wait_stable 12 >/dev/null
    VERDICT=$(oracle checkI3 "{\"excluded\":\"$EXCL\",\"aId\":$A_ID,\"bId\":$B_ID,\"pre\":\"$PRE_SIG\"}")
    if [[ "$VERDICT" == OK* ]]; then
      S4_STATUS="PASS"; S4_DETAIL="A=$A_ID +150px, B=$B_ID absorbed, others still"
    else
      S4_STATUS="FAIL"; S4_DETAIL="A=$A_ID B=$B_ID: $VERDICT"
    fi
  fi
else
  S4_STATUS="FAIL"; S4_DETAIL="4th window never appeared"
fi
record "S4 resize pairwise" "$S4_STATUS" "$S4_DETAIL"

# ---- S5: outline follows focus (I4) -------------------------------------------

S5_STATUS="PASS"
pgrep -xq Calculator || CALC_LAUNCHED=1
# Owner names are localized (e.g. "Calculadora" on es-ES, baseline run
# 2026-06-09), so don't match the name: Calculator's window is whatever
# eligible window is frontmost right after activation, as long as it
# isn't one of ours. `open -a` doesn't reliably steal focus on first try
# (TextEdit re-asserts after its window churn) — retry with re-activation.
CALC_ID=""
for _i in 1 2 3 4 5; do
  open -a Calculator
  sleep 0.5
  CALC_FRONT=$(oracle frontmost "$(excl_json)")
  CALC_ID="${CALC_FRONT%% *}"
  [[ "$CALC_ID" =~ ^[0-9]+$ ]] || CALC_ID=""
  case " ${WIN_IDS[*]:-} " in *" $CALC_ID "*) CALC_ID="" ;; esac
  [ -n "$CALC_ID" ] && break
done
S5_PARTS=()
for tid in ${WIN_IDS[@]+"${WIN_IDS[@]}"}; do
  focus_te "$tid"
  sleep 0.3
  if check_outline "$tid"; then
    S5_PARTS+=("$tid:ok")
  else
    S5_STATUS="FAIL"
    S5_PARTS+=("$tid:[$OUTLINE_DETAIL]")
  fi
done
if [ -n "$CALC_ID" ]; then
  open -a Calculator   # re-activate
  sleep 0.3
  if check_outline "$CALC_ID"; then
    S5_PARTS+=("calc-$CALC_ID:ok")
  else
    S5_STATUS="FAIL"
    S5_PARTS+=("calc-$CALC_ID:[$OUTLINE_DETAIL]")
  fi
else
  S5_STATUS="FAIL"
  S5_PARTS+=("calculator:not-frontmost-after-open (frontmost=$CALC_FRONT)")
fi
[ "$CALC_LAUNCHED" = "1" ] && { killall Calculator >/dev/null 2>&1; CALC_LAUNCHED=0; }
S5_DETAIL="${S5_PARTS[*]:-no-targets}"
record "S5 outline" "$S5_STATUS" "$S5_DETAIL"

# ---- S6: rapid churn -----------------------------------------------------------

S6_STATUS="PASS"; S6_DETAIL=""
if open_qa_window 5; then
  CHURN_A="$OPENED_ID"
  sleep 0.5
  if open_qa_window 6; then
    CHURN_B="$OPENED_ID"
    WIN_IDS+=("$CHURN_B")
    sleep 0.5
    close_win "$CHURN_A"
    sleep 0.5
    minimize "$CHURN_B"
    sleep 0.5
    unminimize "$CHURN_B"
    if wait_converged 20; then
      SIG=$(oracle sig "$(excl_json)")
      if sig_has_id "$SIG" "$CHURN_B"; then
        S6_DETAIL="open2+close1+min1+restore1 settled; $CONV_DETAIL"
      else
        S6_STATUS="FAIL"; S6_DETAIL="restored id=$CHURN_B missing from tiled set after churn"
      fi
    else
      S6_STATUS="FAIL"; S6_DETAIL="$CONV_DETAIL"
    fi
  else
    S6_STATUS="FAIL"; S6_DETAIL="churn window 6 never appeared"
  fi
else
  S6_STATUS="FAIL"; S6_DETAIL="churn window 5 never appeared"
fi
record "S6 churn" "$S6_STATUS" "$S6_DETAIL"

# ---- report --------------------------------------------------------------------

say ""
SUMMARY="summary: $((6 - FAILS))/6 passed, $FAILS failed — $(date '+%Y-%m-%dT%H:%M:%S')"
say "$SUMMARY"

{
  echo "qa-windowscape run — $(date '+%Y-%m-%dT%H:%M:%S')"
  echo "subject app: TextEdit | second app: Calculator | excluded apps: $EXCL"
  echo "oracle: CGWindowList via JXA (no Hammerspoon)"
  echo ""
  for line in "${REPORT_LINES[@]}"; do echo "$line"; done
  echo ""
  echo "$SUMMARY"
} > "$REPORT_FILE"
say "report: $REPORT_FILE"

exit "$FAILS"
