#!/bin/sh
# Keep macOS awake while the Herdr server runs, using caffeinate(8).
#
# Usage: caffeinated.sh start|stop|status|toggle
#
# The caffeinate process waits on the Herdr server PID (-w), so the sleep
# assertion is released automatically when the server exits.

set -u

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-caffeinated}"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-}"
PID_FILE="$STATE_DIR/caffeinate.pid"
PAUSED_FILE="$STATE_DIR/paused"
LOG_FILE="$STATE_DIR/caffeinated.log"
HERDR="${HERDR_BIN_PATH:-herdr}"

# -i: block idle sleep. -m: block disk idle sleep.
# -s: block system sleep (honored by macOS only on AC power).
# Override in $HERDR_PLUGIN_CONFIG_DIR/config with CAFFEINATE_FLAGS="-dims".
CAFFEINATE_FLAGS="-ims"
NOTIFY=1
if [ -n "$CONFIG_DIR" ] && [ -f "$CONFIG_DIR/config" ]; then
  # shellcheck disable=SC1091
  . "$CONFIG_DIR/config"
fi

mkdir -p "$STATE_DIR"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE"
  printf '%s\n' "$*"
}

notify() {
  [ "$NOTIFY" = 1 ] || return 0
  "$HERDR" notification show "$1" --body "$2" --sound none >/dev/null 2>&1 || true
}

is_herdr_server() {
  case "$(ps -o command= -p "$1" 2>/dev/null)" in
    *herdr\ server*) return 0 ;;
  esac
  return 1
}

# Find the Herdr server PID. Prefer our own ancestor chain, because hooks and
# actions are spawned by the server. Fall back to the process that owns the
# API socket.
find_server_pid() {
  pid=$$
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    if is_herdr_server "$pid"; then
      echo "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done

  if [ -n "${HERDR_SOCKET_PATH:-}" ] && command -v lsof >/dev/null 2>&1; then
    for pid in $(lsof -t "$HERDR_SOCKET_PATH" 2>/dev/null); do
      if is_herdr_server "$pid"; then
        echo "$pid"
        return 0
      fi
    done
  fi
  return 1
}

running_pid() {
  [ -f "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    *caffeinate*) echo "$pid"; return 0 ;;
  esac
  rm -f "$PID_FILE"
  return 1
}

do_start() {
  if ! command -v caffeinate >/dev/null 2>&1; then
    log "caffeinate not found; this plugin needs macOS"
    return 1
  fi

  server_pid=$(find_server_pid) || {
    log "cannot find the herdr server process"
    return 1
  }

  if pid=$(running_pid); then
    # A previous server (for example before a live handoff) may own it.
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      *"-w $server_pid"*)
        log "already active (caffeinate pid $pid, herdr server pid $server_pid)"
        return 0
        ;;
    esac
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
  fi

  # Detach fully so the hook can exit while caffeinate keeps running.
  # shellcheck disable=SC2086
  nohup caffeinate $CAFFEINATE_FLAGS -w "$server_pid" </dev/null >/dev/null 2>&1 &
  pid=$!
  echo "$pid" >"$PID_FILE"
  rm -f "$PAUSED_FILE"
  log "active: caffeinate $CAFFEINATE_FLAGS -w $server_pid (pid $pid)"
}

do_stop() {
  if pid=$(running_pid); then
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    log "stopped caffeinate pid $pid"
  else
    log "not active"
  fi
}

do_status() {
  if pid=$(running_pid); then
    msg="Active: $(ps -o command= -p "$pid" | sed 's/^ *//') (pid $pid)"
  elif [ -f "$PAUSED_FILE" ]; then
    msg="Paused. Mac can sleep."
  else
    msg="Inactive. Mac can sleep."
  fi
  echo "$msg"
  notify "Caffeinated" "$msg"
}

case "${1:-status}" in
  startup)
    # Respect a manual pause across server restarts.
    if [ -f "$PAUSED_FILE" ]; then
      log "paused; skipping startup"
      exit 0
    fi
    do_start
    ;;
  start)
    do_start && notify "Caffeinated" "Mac stays awake while herdr runs."
    ;;
  stop)
    do_stop
    touch "$PAUSED_FILE"
    notify "Caffeinated" "Paused. Mac can sleep."
    ;;
  toggle)
    if running_pid >/dev/null; then
      do_stop
      touch "$PAUSED_FILE"
      notify "Caffeinated" "Paused. Mac can sleep."
    else
      do_start && notify "Caffeinated" "Mac stays awake while herdr runs."
    fi
    ;;
  status)
    do_status
    ;;
  *)
    echo "usage: $0 start|stop|toggle|status" >&2
    exit 2
    ;;
esac
