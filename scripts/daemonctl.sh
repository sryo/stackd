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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/.build/stackd"
LOG="$REPO_ROOT/.build/stackd.log"
STATE_DIR="$HOME/Library/Application Support/stackd"
PID_FILE="$STATE_DIR/daemon.pid"
SOCK_FILE="$STATE_DIR/daemon.sock"
STOP_TIMEOUT_SECS="${STACKD_STOP_TIMEOUT:-5}"

log()  { printf '[daemonctl] %s\n' "$*" >&2; }
fail() { log "$*"; exit 1; }

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

cmd_stop() {
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
    status)  cmd_status ;;
    stop)    cmd_stop ;;
    start)   cmd_start "$@" ;;
    restart) cmd_restart "$@" ;;
    rebuild) cmd_rebuild "$@" ;;
    *) fail "unknown subcommand: $sub (status|stop|start|restart|rebuild)" ;;
  esac
}

main "$@"
