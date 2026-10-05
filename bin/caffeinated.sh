#!/bin/sh
# Keep macOS awake while Herdr agents work, using caffeinate(8).
#
# Usage: caffeinated.sh reconcile|start|stop|toggle|status
#
# Herdr runs "reconcile" at startup and on agent/pane events. When any agent
# is working, a "caffeinate -w <herdr server pid>" process holds the sleep
# assertion. When no agent works, a one-shot timer waits for the grace
# period, checks again, and releases the assertion. The -w flag also
# releases it if the Herdr server exits.

set -u

HERDR="${HERDR_BIN_PATH:-herdr}"
CAFFEINATE_BIN="${HERDR_CAFFEINATE_BIN:-/usr/bin/caffeinate}"
SCRIPT_PATH=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")

# Defaults. Override in $HERDR_PLUGIN_CONFIG_DIR/config (key=value lines).
CAFFEINATE_FLAGS="-ims"
IDLE_GRACE_SECONDS=60
AWAKE_STATUSES="working"
REQUEST_TIMEOUT_SECONDS=5
NOTIFY=1

LOCK_STALE_SECONDS=30
SERVER_FAILURE_LIMIT=3

is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
}

load_config() {
  file="${HERDR_PLUGIN_CONFIG_DIR:-}/config"
  [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "$file" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key=$(printf '%s' "$key" | tr -d ' \t')
    value=$(printf '%s' "$value" | sed 's/^[ \t"]*//; s/[ \t"]*$//')
    case "$key" in
      caffeinate_flags)
        case "$value" in -*[!dimsu]* | '' | -) ;; -*) CAFFEINATE_FLAGS=$value ;; esac
        ;;
      idle_grace_seconds) is_uint "$value" && IDLE_GRACE_SECONDS=$value ;;
      request_timeout_seconds)
        is_uint "$value" && [ "$value" -gt 0 ] && REQUEST_TIMEOUT_SECONDS=$value
        ;;
      awake_statuses)
        case "$value" in *[!a-z_,]* | '') ;; *) AWAKE_STATUSES=$value ;; esac
        ;;
      notify) case "$value" in 0 | 1) NOTIFY=$value ;; esac ;;
    esac
  done <"$file"
}

init_state() {
  base="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-caffeinated}"
  # Plugins are shared by all Herdr sessions, so keep state per socket.
  socket="${HERDR_SOCKET_PATH:-default}"
  SESSION_DIR="$base/session-$(/sbin/md5 -q -s "$socket")"
  PID_FILE="$SESSION_DIR/caffeinate.pid"
  PAUSED_FILE="$SESSION_DIR/paused"
  IDLE_FILE="$SESSION_DIR/idle-token"
  LOCK_DIR="$SESSION_DIR/lock"
  LOG_FILE="$SESSION_DIR/caffeinated.log"
  mkdir -p "$SESSION_DIR"
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE"
  printf '%s\n' "$*"
}

notify() {
  [ "$NOTIFY" = 1 ] || return 0
  "$HERDR" notification show "$1" --body "$2" --sound none >/dev/null 2>&1 || true
}

acquire_lock() {
  tries=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      modified=$(stat -f '%m' "$LOCK_DIR" 2>/dev/null) || modified=0
      if [ $(($(date +%s) - modified)) -ge "$LOCK_STALE_SECONDS" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null
        tries=0
        continue
      fi
      log "lock busy; giving up"
      return 1
    fi
    sleep 0.1
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
  trap 'exit 1' HUP INT TERM
}

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null
  trap - EXIT HUP INT TERM
}

# Print `herdr agent list` JSON. Fails on error or after the timeout.
read_agents() {
  # Run in its own process group so the timeout kills every child that
  # holds the output pipe.
  /usr/bin/perl -e '
    my $t = shift;
    my $pid = fork() // exit 125;
    if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 }
    local $SIG{ALRM} = sub { kill "KILL", -$pid, $pid; waitpid $pid, 0; exit 124 };
    alarm $t;
    waitpid $pid, 0;
    exit($? & 127 ? 1 : $? >> 8);
  ' "$REQUEST_TIMEOUT_SECONDS" "$HERDR" agent list 2>/dev/null
}

# Count agents whose status is in AWAKE_STATUSES.
count_awake() {
  compact=$(printf '%s' "$1" | tr -d '[:space:]')
  total=0
  for status in $(printf '%s' "$AWAKE_STATUSES" | tr ',' ' '); do
    n=$(printf '%s' "$compact" | grep -o "\"agent_status\":\"$status\"" | wc -l | tr -d ' ')
    total=$((total + n))
  done
  echo "$total"
}

is_herdr_server() {
  case "$(ps -o command= -p "$1" 2>/dev/null)" in
    *herdr*server*) return 0 ;;
  esac
  return 1
}

# Find the Herdr server PID: our ancestor chain first (hooks are spawned by
# the server), then the process that owns the API socket.
find_server_pid() {
  if [ -n "${HERDR_CAFFEINATED_SERVER_PID:-}" ]; then
    echo "$HERDR_CAFFEINATED_SERVER_PID"
    return 0
  fi
  pid=$$
  while is_uint "$pid" && [ "$pid" -gt 1 ]; do
    if is_herdr_server "$pid"; then
      echo "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
    for pid in $(lsof -t "$HERDR_SOCKET_PATH" 2>/dev/null); do
      if is_herdr_server "$pid"; then
        echo "$pid"
        return 0
      fi
    done
  fi
  return 1
}

# Print the PID of our live caffeinate process, if any.
running_pid() {
  [ -f "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null)
  if is_uint "$pid"; then
    case "$(ps -o state=,command= -p "$pid" 2>/dev/null)" in
      Z*) ;;
      *caffeinate*-w\ *) echo "$pid"; return 0 ;;
    esac
  fi
  rm -f "$PID_FILE"
  return 1
}

ensure_caffeinate() {
  server_pid=$(find_server_pid) || {
    log "cannot find the herdr server process"
    return 1
  }
  if pid=$(running_pid); then
    case "$(ps -o command= -p "$pid")" in
      *" -w $server_pid") return 0 ;;
    esac
    # Left over from an earlier server (for example a live handoff).
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
  fi

  # shellcheck disable=SC2086
  nohup "$CAFFEINATE_BIN" $CAFFEINATE_FLAGS -w "$server_pid" </dev/null >/dev/null 2>&1 &
  pid=$!
  sleep 0.1
  if ! kill -0 "$pid" 2>/dev/null; then
    log "caffeinate failed to start"
    return 1
  fi
  printf '%s\n' "$pid" >"$PID_FILE.$$" && mv "$PID_FILE.$$" "$PID_FILE"
  log "awake: caffeinate $CAFFEINATE_FLAGS -w $server_pid (pid $pid)"
}

stop_caffeinate() {
  rm -f "$IDLE_FILE"
  if pid=$(running_pid); then
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    log "released: stopped caffeinate pid $pid"
  fi
}

# Start a detached timer that releases the assertion after the grace period.
schedule_release() {
  [ -f "$IDLE_FILE" ] && return 0
  token="$(date +%s).$$"
  printf '%s\n' "$token" >"$IDLE_FILE"
  nohup sh "$SCRIPT_PATH" idle-check "$token" </dev/null >/dev/null 2>&1 &
  log "no working agents; release in ${IDLE_GRACE_SECONDS}s"
}

token_is() {
  [ -f "$IDLE_FILE" ] && [ "$(cat "$IDLE_FILE")" = "$1" ]
}

reconcile() {
  acquire_lock || return 1
  if [ -f "$PAUSED_FILE" ]; then
    stop_caffeinate
  elif agents=$(read_agents); then
    if [ "$(count_awake "$agents")" -gt 0 ]; then
      rm -f "$IDLE_FILE"
      ensure_caffeinate
    elif running_pid >/dev/null; then
      schedule_release
    else
      rm -f "$IDLE_FILE"
    fi
  fi
  # If the server does not answer, keep the current state.
  release_lock
}

idle_check() {
  token=$1
  failures=0
  while :; do
    sleep "$IDLE_GRACE_SECONDS"
    acquire_lock || return 1
    if ! token_is "$token"; then
      release_lock
      return 0
    fi
    if agents=$(read_agents); then
      if [ "$(count_awake "$agents")" -gt 0 ]; then
        rm -f "$IDLE_FILE"
        ensure_caffeinate
      else
        stop_caffeinate
      fi
      release_lock
      return 0
    fi
    failures=$((failures + 1))
    if [ "$failures" -ge "$SERVER_FAILURE_LIMIT" ]; then
      log "herdr not responding; releasing"
      stop_caffeinate
      release_lock
      return 0
    fi
    release_lock
  done
}

status() {
  if [ -f "$PAUSED_FILE" ]; then
    msg="Paused. Mac can sleep."
  elif pid=$(running_pid); then
    if [ -f "$IDLE_FILE" ]; then
      msg="Awake. No agent works; release in under ${IDLE_GRACE_SECONDS}s."
    else
      msg="Awake while agents work (caffeinate pid $pid)."
    fi
  else
    msg="Idle. Mac can sleep until an agent works."
  fi
  echo "$msg"
  notify "Caffeinated" "$msg"
}

pause() {
  touch "$PAUSED_FILE"
  acquire_lock && stop_caffeinate && release_lock
  notify "Caffeinated" "Paused. Mac can sleep."
}

resume() {
  rm -f "$PAUSED_FILE"
  reconcile
  notify "Caffeinated" "On. Mac stays awake while agents work."
}

load_config
init_state

case "${1:-status}" in
  reconcile) reconcile ;;
  idle-check) idle_check "${2:?token required}" ;;
  start) resume ;;
  stop) pause ;;
  toggle) if [ -f "$PAUSED_FILE" ]; then resume; else pause; fi ;;
  status) status ;;
  *)
    echo "usage: $0 reconcile|start|stop|toggle|status" >&2
    exit 2
    ;;
esac
