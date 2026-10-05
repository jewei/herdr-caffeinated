#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC2329 # checks eval quoted expressions
# Lifecycle tests with fake herdr and caffeinate binaries. Prints TAP.
# Run: sh tests/test-plugin.sh
#
# The tests run a copy of the plugin in a temp dir and clean up only
# processes under that dir, so a linked live copy is never touched.
# A fake herdr server is a marker file $T/servers/<pid>; the fake caffeinate
# runs while the marker for its -w pid exists.

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr-caffeinated-test.XXXXXX") || exit 1
T=$(CDPATH='' cd -- "$T" && pwd) # normalize "//" so pgrep patterns match
SCRIPT=$T/plugin/bin/caffeinated.sh
N=0
FAILED=0

cleanup() {
  pkill -f "$T/" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$T/plugin" "$T/bin" "$T/state" "$T/config" "$T/servers"
cp -R "$ROOT/bin" "$T/plugin/"

cat >"$T/bin/herdr" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "agent list") ;;
  "notification show") echo "$*" >>"$FAKE_DIR/toasts" && exit 0 ;;
  *) exit 2 ;;
esac
status=$(cat "$FAKE_DIR/status")
case $status in
  down) exit 1 ;;
  hung) sleep 30 && exit 1 ;;
esac
printf '{"result":{"agents":[{"agent_status":"idle"},{"agent_status":"%s"}]}}\n' "$status"
EOF

cat >"$T/bin/caffeinate" <<'EOF'
#!/bin/sh
t=0 w=
while [ $# -gt 0 ]; do
  case $1 in -t) t=$2 && shift ;; -w) w=$2 && shift ;; esac
  shift
done
n=0
while [ -e "$FAKE_DIR/servers/$w" ]; do
  [ "$t" -gt 0 ] && [ "$n" -ge $((t * 10)) ] && exit 0
  sleep 0.1
  n=$((n + 1))
done
EOF
chmod +x "$T/bin/herdr" "$T/bin/caffeinate"
echo 'idle_grace_seconds=1' >"$T/config/config"

# run SESSION SERVER_PID COMMAND: sets OUT (stdout) and RC.
run() {
  OUT=$(FAKE_DIR="$T" \
    HERDR_BIN_PATH="$T/bin/herdr" \
    HERDR_SOCKET_PATH="$T/$1.sock" \
    HERDR_PLUGIN_STATE_DIR="$T/state" \
    HERDR_PLUGIN_CONFIG_DIR="$T/config" \
    CAFFEINATED_BIN="$T/bin/caffeinate" \
    CAFFEINATED_SERVER_PID="$2" \
    CAFFEINATED_TIMEOUT=1 \
    sh "$SCRIPT" "$3" 2>"$T/stderr")
  RC=$?
}

set_status() { echo "$1" >"$T/status"; }
server_up() { touch "$T/servers/$1"; }
server_down() { rm -f "$T/servers/$1"; }
session_dir() { echo "$T/state/session-$(/sbin/md5 -q -s "$T/$1.sock")"; }
pid_of() { cat "$(session_dir "$1")/caffeinate.pid" 2>/dev/null || echo none; }
count() { pgrep -f "$T/bin/caffeinate" | wc -l | tr -d ' '; }

# Print the args of a session's tracked caffeinate, or "none".
caf() {
  cmd=$(ps -o command= -p "$(pid_of "$1")" 2>/dev/null) || cmd=''
  case $cmd in *caffeinate\ *) echo "${cmd#*caffeinate }" ;; *) echo none ;; esac
}

# check DESC EXPR WANT: evaluate EXPR once.
check() {
  N=$((N + 1))
  got=$(eval "$2")
  if [ "$got" = "$3" ]; then
    echo "ok $N - $1"
  else
    echo "not ok $N - $1 # got '$got', want '$3'"
    FAILED=1
  fi
}

# eventually DESC EXPR WANT: retry EXPR for up to 4 seconds, then check.
eventually() {
  i=0
  while [ "$(eval "$2")" != "$3" ] && [ "$i" -lt 40 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  check "$@"
}

server_up 10698
set_status working

# Hold and release
run a 10698 reconcile
check "working agent starts caffeinate" 'caf a' "-ims -w 10698"
first=$(pid_of a)
run a 10698 reconcile
check "repeat reconcile keeps the same process" 'pid_of a' "$first"
check "repeat reconcile starts no extra process" count 1

set_status idle
run a 10698 reconcile
check "idle swaps to a timed caffeinate" 'caf a' "-ims -t 1 -w 10698"
eventually "swap leaves one process" count 1
eventually "timed caffeinate ends after the grace period" 'caf a' none
run a 10698 reconcile
check "idle with nothing running starts nothing" count 0

set_status working
run a 10698 reconcile
set_status idle
run a 10698 reconcile
set_status working
run a 10698 reconcile
check "work during grace swaps back to hold" 'caf a' "-ims -w 10698"
sleep 1.5
check "hold outlives the grace period" 'caf a' "-ims -w 10698"

# Failures keep state and fail the hook
set_status down
run a 10698 reconcile
check "unreachable herdr fails the hook" 'echo $RC' 1
check "unreachable herdr keeps state" 'caf a' "-ims -w 10698"
set_status hung
started=$(date +%s)
run a 10698 reconcile
check "hung herdr times out" 'echo $(($(date +%s) - started <= 3))' 1
check "hung herdr keeps state" 'caf a' "-ims -w 10698"

# Status, pause, resume, toggle
set_status working
run a 10698 status
check "status reports awake" 'echo "$OUT"' "state=awake pid=$(pid_of a) server_pid=10698 grace=1 flags=-ims"
run a 10698 pause
check "pause releases" 'caf a' none
eventually "pause leaves no process" count 0
check "pause shows a toast" 'grep -c Paused "$T/toasts"' 1
run a 10698 reconcile
check "paused session ignores working agents" 'caf a' none
run a 10698 status
check "status reports paused" 'echo "${OUT%% *}"' state=paused
run a 10698 toggle
check "toggle resumes" 'caf a' "-ims -w 10698"
run a 10698 toggle
check "toggle pauses" 'caf a' none
run a 10698 resume
check "resume holds again" 'caf a' "-ims -w 10698"

set_status idle
run a 10698 reconcile
run a 10698 status
check "status reports releasing" 'echo "${OUT%% *}"' state=releasing
run a 10698 pause
eventually "pause during grace leaves no process" count 0
run a 10698 resume
check "resume while idle starts nothing" 'caf a' none
run a 10698 status
check "status reports idle" 'echo "${OUT%% *}"' state=idle

# Sessions are independent
set_status working
run a 10698 reconcile
server_up 20000
run b 20000 reconcile
check "second session gets its own caffeinate" 'caf b' "-ims -w 20000"
check "first session keeps its caffeinate" 'caf a' "-ims -w 10698"
run b 20000 pause
check "pausing one session leaves the other" 'caf a' "-ims -w 10698"

# Server handoff and exit (106 must not match 10698)
server_up 106
run a 106 reconcile
check "new server pid gets a new caffeinate" 'caf a' "-ims -w 106"
server_down 10698
eventually "old caffeinate ends with the old server" count 1
server_down 106
eventually "server exit ends caffeinate" count 0

# Concurrent hooks start one caffeinate
server_up 30000
i=0
while [ "$i" -lt 10 ]; do
  run c 30000 reconcile &
  i=$((i + 1))
done
wait
check "10 concurrent hooks start one process" count 1

# Config
server_up 40000
printf '%s\n' '# comment' 'idle_grace_seconds = 1' 'awake_statuses = "working,blocked"' \
  'caffeinate_flags=-dims' >"$T/config/config"
set_status blocked
run d 40000 reconcile
check "awake_statuses and flags apply" 'caf d' "-dims -w 40000"
printf '%s\n' 'idle_grace_seconds=1' 'caffeinate_flags=-w' >"$T/config/config"
run d 40000 status
check "invalid flags fall back to the default" 'echo "${OUT##* }"' flags=-ims
check "invalid config is reported" 'cat "$T/stderr"' "config: ignored caffeinate_flags=-w"

# Command line
check "unknown command exits 2" 'sh "$SCRIPT" bogus 2>/dev/null; echo $?' 2
check "run outside herdr exits 2" 'HERDR_PLUGIN_STATE_DIR= sh "$SCRIPT" status 2>/dev/null; echo $?' 2

echo "1..$N"
exit "$FAILED"
