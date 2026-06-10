#!/usr/bin/env bash
# daemonctl.sh — one canonical safe restart for the stackd daemon.
#
# Replaces ad-hoc `pkill stackd` + manual launch. The pid file and socket
# live at "$HOME/Library/Application Support/stackd/" (see Sources/IPC.swift).
#
# Usage:
#   scripts/daemonctl.sh status
#   scripts/daemonctl.sh stop
#   scripts/daemonctl.sh start    [extra args forwarded to .build/stackd]
#   scripts/daemonctl.sh restart  [extra args]
#   scripts/daemonctl.sh rebuild  [extra args]   # ./build.sh && restart
#   scripts/daemonctl.sh install      # launchd LaunchAgent with KeepAlive
#   scripts/daemonctl.sh uninstall    # bootout + remove the plist
#   scripts/daemonctl.sh print-plist  # emit the plist to stdout (lintable)
#
# install is opt-in: the nohup dev workflow above keeps working untouched.
# Once installed, stop/start/restart route through launchctl so KeepAlive
# doesn't resurrect the daemon mid-rebuild.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/.build/stackd"
LOG="$REPO_ROOT/.build/stackd.log"
STATE_DIR="$HOME/Library/Application Support/stackd"
PID_FILE="$STATE_DIR/daemon.pid"
SOCK_FILE="$STATE_DIR/daemon.sock"
STOP_TIMEOUT_SECS="${STACKD_STOP_TIMEOUT:-5}"
# Label/path match the pre-existing hand-written LaunchAgent (discovered
# 2026-06-09) so install REWRITES it instead of fighting it under a second
# label. That plist had unconditional KeepAlive:true — every daemonctl stop
# was silently resurrected by launchd within seconds.
LAUNCHD_LABEL="stackd"
PLIST_PATH="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

log()  { printf '[daemonctl] %s\n' "$*" >&2; }
fail() { log "$*"; exit 1; }

launchd_managed() {
  launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1
}

current_pid() {
  # Prefer pid file; fall back to pgrep against the literal binary path.
  if [[ -f "$PID_FILE" ]]; then
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi
  # Resilient fallback: only matches our own binary, not other "stackd" strings.
  pgrep -f "^$BIN($| )" 2>/dev/null | head -n 1 || true
}

cmd_status() {
  local pid; pid="$(current_pid)"
  if [[ -n "$pid" ]]; then
    log "running pid=$pid"
    [[ -S "$SOCK_FILE" ]] && log "socket=$SOCK_FILE present" || log "socket=$SOCK_FILE MISSING (pid running but socket gone)"
    return 0
  fi
  log "not running"
  [[ -S "$SOCK_FILE" ]] && log "stale socket present: $SOCK_FILE"
  return 1
}

# KeepAlive {SuccessfulExit: false} restarts the daemon on crashes and
# signal deaths but NOT on a clean exit(0). ThrottleInterval 5 keeps a
# crash-on-launch binary from hot-looping. gui/$UID domain gives the Aqua
# session AppKit needs.
print_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_ROOT</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
}

cmd_install() {
  [[ -x "$BIN" ]] || fail "binary not found: $BIN — run ./build.sh first"
  if launchd_managed; then
    log "already installed — reinstalling"
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
    # bootout is async — bootstrapping before the unload settles fails
    # with EIO (5). Poll until the service is really gone.
    for _ in $(seq 1 10); do
      launchd_managed || break
      sleep 0.5
    done
  elif [[ -n "$(current_pid)" ]]; then
    fail "a manually-launched instance is running — 'daemonctl.sh stop' first"
  fi
  mkdir -p "$(dirname "$PLIST_PATH")"
  print_plist > "$PLIST_PATH"
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  log "installed $PLIST_PATH (KeepAlive on — crashes self-restart)"
}

cmd_uninstall() {
  launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  log "uninstalled (plist removed; daemon stopped if it was running)"
}

cmd_stop() {
  if launchd_managed; then
    log "launchd-managed — bootout (plist kept; 'start' re-bootstraps)"
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL"
    return 0
  fi
  local pid; pid="$(current_pid)"
  if [[ -z "$pid" ]]; then
    log "not running"
    # Clean up stale socket even if we didn't kill anything.
    [[ -S "$SOCK_FILE" ]] && rm -f "$SOCK_FILE" && log "removed stale socket"
    return 0
  fi
  log "stopping pid=$pid (SIGTERM, ${STOP_TIMEOUT_SECS}s timeout)"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 "$STOP_TIMEOUT_SECS"); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "stopped"
      [[ -S "$SOCK_FILE" ]] && rm -f "$SOCK_FILE" && log "removed socket"
      [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
      return 0
    fi
    sleep 1
  done
  log "SIGTERM timed out — sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  sleep 1
  [[ -S "$SOCK_FILE" ]] && rm -f "$SOCK_FILE"
  [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
}

cmd_start() {
  [[ -x "$BIN" ]] || fail "binary not found: $BIN — run ./build.sh first"
  if launchd_managed; then
    fail "already running under launchd — use restart"
  fi
  if [[ -f "$PLIST_PATH" ]]; then
    log "installed plist found — bootstrapping via launchd"
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    return 0
  fi
  local existing; existing="$(current_pid)"
  if [[ -n "$existing" ]]; then
    fail "already running pid=$existing — use restart, not start"
  fi
  log "launching $BIN $* (log: $LOG)"
  nohup "$BIN" "$@" >>"$LOG" 2>&1 &
  local pid=$!
  # Give the daemon a moment to write its socket; surface obvious crashes.
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "daemon exited immediately — tail $LOG"
  fi
  log "running pid=$pid"
}

cmd_restart() {
  if launchd_managed; then
    log "launchd-managed — kickstart -k"
    launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL"
    return 0
  fi
  cmd_stop
  cmd_start "$@"
}

cmd_rebuild() {
  log "./build.sh"
  ( cd "$REPO_ROOT" && ./build.sh )
  cmd_restart "$@"
}

main() {
  local sub="${1:-status}"
  shift || true
  case "$sub" in
    status)      cmd_status ;;
    stop)        cmd_stop ;;
    start)       cmd_start "$@" ;;
    restart)     cmd_restart "$@" ;;
    rebuild)     cmd_rebuild "$@" ;;
    install)     cmd_install ;;
    uninstall)   cmd_uninstall ;;
    print-plist) print_plist ;;
    *) fail "unknown subcommand: $sub (status|stop|start|restart|rebuild|install|uninstall|print-plist)" ;;
  esac
}

main "$@"
