#!/bin/sh
# Herdr Caffeinated: keep macOS awake while Herdr agents work.
#
# Usage: caffeinated.sh reconcile|pause|resume|toggle|status
#
# Herdr runs "reconcile" at startup and on agent, pane, tab, and workspace
# events. While an agent works, "caffeinate -w <server pid>" holds a sleep
# assertion. When no agent works, "caffeinate -t <grace> -w <server pid>"
# replaces it, so the assertion ends on its own after the grace period.
# -w also ends it when the Herdr server exits.
#
# Test-only overrides: CAFFEINATED_BIN, CAFFEINATED_SERVER_PID,
# CAFFEINATED_TIMEOUT.

set -u
# System tools first, so GNU coreutils in the user's PATH cannot shadow them.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

HERDR=${HERDR_BIN_PATH:-herdr}
CAFFEINATE=${CAFFEINATED_BIN:-/usr/bin/caffeinate}
SERVER_PID=${CAFFEINATED_SERVER_PID:-$PPID} # hooks are children of the server
TIMEOUT=${CAFFEINATED_TIMEOUT:-5}
LOCK_TIMEOUT=30

# Defaults. Override in $HERDR_PLUGIN_CONFIG_DIR/config.
FLAGS=-ims
GRACE=60
AWAKE_STATUSES=working

# perl [lock_seconds] [timeout] [argv...]
# lock_seconds > 0: take an exclusive flock on fd 9. The lock belongs to the
# shell's open file, so it stays held until the shell closes fd 9 or exits.
# argv: run it in its own process group; kill the group after the timeout.
# shellcheck disable=SC2016 # perl code, not shell
PERL_RUN='
use Fcntl ":flock";
my ($lock, $timeout) = splice @ARGV, 0, 2;
if ($lock) {
  open(my $fh, ">&=", 9) or exit 125;
  local $SIG{ALRM} = sub { exit 75 };
  alarm $lock;
  flock($fh, LOCK_EX) or exit 75;
  alarm 0;
}
exit 0 unless @ARGV;
my $pid = fork() // exit 125;
if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 }
$SIG{ALRM} = sub { kill "KILL", -$pid, $pid; waitpid $pid, 0; exit 124 };
alarm $timeout;
waitpid $pid, 0;
exit($? & 127 ? 1 : $? >> 8);
'

run_timed() {
  /usr/bin/perl -e "$PERL_RUN" "$@"
}

lock() {
  exec 9>>"$SESSION_DIR/lock"
  run_timed "$LOCK_TIMEOUT" 0 || {
    echo "error: lock busy" >&2
    return 1
  }
}

unlock() {
  exec 9>&-
}

toast() {
  run_timed 0 "$TIMEOUT" "$HERDR" notification show "Caffeinated" \
    --body "$1" --sound none >/dev/null 2>&1
}

load_config() {
  file=${HERDR_PLUGIN_CONFIG_DIR:-}/config
  [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "$file" ] || return 0
  while IFS='= 	' read -r key value || [ -n "$key" ]; do
    case $value in \"*\") value=${value#\"} value=${value%\"} ;; esac
    case $key in
      '' | \#*) continue ;;
      caffeinate_flags)
        case $value in -*[!dimsu]* | - | '') ;; -*) FLAGS=$value && continue ;; esac
        ;;
      idle_grace_seconds)
        case $value in '' | *[!0-9]* | 0*) ;; *) GRACE=$value && continue ;; esac
        ;;
      awake_statuses)
        case $value in '' | *[!a-z_,]*) ;; *) AWAKE_STATUSES=$value && continue ;; esac
        ;;
    esac
    echo "config: ignored $key=$value" >&2
  done <"$file"
}

# Succeed if the agent list JSON has an agent in one of AWAKE_STATUSES.
agents_awake() {
  old_ifs=$IFS
  IFS=,
  for status in $AWAKE_STATUSES; do
    case $1 in *"\"agent_status\":\"$status\""*) IFS=$old_ifs && return 0 ;; esac
  done
  IFS=$old_ifs
  return 1
}

# Set CUR_PID and CUR_MODE (hold or grace) for this session's caffeinate.
# Only an exact "-w <server pid>" match counts, so a reused PID never does.
find_caffeinate() {
  CUR_PID='' CUR_MODE=''
  [ -f "$PID_FILE" ] && read -r pid <"$PID_FILE" || return 1
  case $(ps -o state=,command= -p "$pid" 2>/dev/null) in
    Z*) return 1 ;;
    *caffeinate*" -t "*" -w $SERVER_PID") CUR_MODE=grace ;;
    *caffeinate*" -w $SERVER_PID") CUR_MODE=hold ;;
    *) return 1 ;;
  esac
  CUR_PID=$pid
}

# Start caffeinate with extra args ("-t GRACE" or none), then stop the
# process it replaces, so the assertion has no gap.
start_caffeinate() {
  if [ -z "${CAFFEINATED_SERVER_PID:-}" ]; then
    case $(ps -o command= -p "$SERVER_PID" 2>/dev/null) in
      *herdr*) ;;
      *)
        echo "error: parent pid $SERVER_PID is not the herdr server" >&2
        return 1
        ;;
    esac
  fi
  # shellcheck disable=SC2086 # FLAGS is validated to -[dimsu]+
  nohup "$CAFFEINATE" $FLAGS "$@" -w "$SERVER_PID" </dev/null >/dev/null 2>&1 9>&- &
  echo "$!" >"$PID_FILE"
  [ -n "$CUR_PID" ] && kill "$CUR_PID" 2>/dev/null
  echo "caffeinate $FLAGS${1:+ $*} -w $SERVER_PID (pid $!)"
}

stop_caffeinate() {
  [ -n "$CUR_PID" ] || return 0
  kill "$CUR_PID" 2>/dev/null
  rm -f "$PID_FILE"
  echo "released caffeinate pid $CUR_PID"
}

cmd_reconcile() {
  exec 9>>"$SESSION_DIR/lock"
  agents=$(run_timed "$LOCK_TIMEOUT" "$TIMEOUT" "$HERDR" agent list 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 75 ]; then
    echo "error: lock busy" >&2
    return 1
  fi
  find_caffeinate
  if [ -f "$PAUSED_FILE" ]; then
    stop_caffeinate
  elif [ "$rc" -ne 0 ]; then
    echo "error: herdr agent list failed (exit $rc); state kept" >&2
    return 1
  elif agents_awake "$agents"; then
    [ "$CUR_MODE" = hold ] || start_caffeinate
  elif [ "$CUR_MODE" = hold ]; then
    start_caffeinate -t "$GRACE"
  fi
}

cmd_pause() {
  lock || return 1
  touch "$PAUSED_FILE"
  find_caffeinate
  stop_caffeinate
  unlock
  toast "Paused. Mac can sleep."
}

cmd_resume() {
  lock || return 1
  rm -f "$PAUSED_FILE"
  unlock
  if cmd_reconcile; then
    unlock
    toast "On. Mac stays awake while agents work."
  else
    unlock
    toast "On, but the agent check failed. See the plugin log."
    return 1
  fi
}

cmd_status() {
  find_caffeinate
  if [ -f "$PAUSED_FILE" ]; then
    state=paused text="Paused. Mac can sleep."
  elif [ "$CUR_MODE" = hold ]; then
    state=awake text="Awake while agents work."
  elif [ "$CUR_MODE" = grace ]; then
    state=releasing text="No agent works. Mac can sleep in ${GRACE}s or less."
  else
    state=idle text="Idle. Mac can sleep until an agent works."
  fi
  echo "state=$state pid=${CUR_PID:--} server_pid=$SERVER_PID grace=$GRACE flags=$FLAGS"
  toast "$text"
}

case ${1:-} in
  reconcile | pause | resume | toggle | status) ;;
  *)
    echo "usage: $0 reconcile|pause|resume|toggle|status" >&2
    exit 2
    ;;
esac

if [ -z "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
  echo "error: run through herdr, for example:" >&2
  echo "  herdr plugin action invoke herdr-caffeinated.status" >&2
  exit 2
fi
# Plugins are shared by all Herdr sessions, so keep state per socket.
SESSION_DIR=$HERDR_PLUGIN_STATE_DIR/session-$(/sbin/md5 -q -s "${HERDR_SOCKET_PATH:-default}")
PID_FILE=$SESSION_DIR/caffeinate.pid
PAUSED_FILE=$SESSION_DIR/paused
[ -d "$SESSION_DIR" ] || mkdir -p "$SESSION_DIR"
load_config

case $1 in
  toggle) if [ -f "$PAUSED_FILE" ]; then cmd_resume; else cmd_pause; fi ;;
  *) "cmd_$1" ;;
esac
