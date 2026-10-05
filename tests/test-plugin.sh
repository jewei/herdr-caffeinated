#!/bin/sh
# Lifecycle tests with fake herdr and caffeinate binaries.
# Run: sh tests/test-plugin.sh

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/bin/caffeinated.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr-caffeinated-test.XXXXXX")
mkdir -p "$T/bin" "$T/state" "$T/config"
FAILED=0

# A stand-in for the herdr server process that caffeinate waits on.
sleep 600 &
SERVER_PID=$!

cleanup() {
  pkill -f "$T/bin/caffeinate" 2>/dev/null
  pkill -f "$SCRIPT idle-check" 2>/dev/null
  kill "$SERVER_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT HUP INT TERM

cat >"$T/bin/herdr" <<'EOF'
#!/bin/sh
[ "$1 $2" = "agent list" ] || exit 0
status=$(cat "$HERDR_TEST_STATUS_FILE")
case "$status" in
  down) exit 1 ;;
  hung) sleep 60; exit 1 ;;
esac
printf '{"result":{"agents":[{"agent_status":"idle"},{"agent_status":"%s"}]}}\n' "$status"
EOF

cat >"$T/bin/caffeinate" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  [ "$1" = "-w" ] && watched=$2
  shift
done
while kill -0 "$watched" 2>/dev/null; do sleep 0.1; done
EOF
chmod +x "$T/bin/herdr" "$T/bin/caffeinate"

printf '%s\n' 'idle_grace_seconds=1' 'request_timeout_seconds=1' 'notify=0' >"$T/config/config"

run() {
  socket=${SOCKET:-$T/a.sock}
  HERDR_BIN_PATH="$T/bin/herdr" \
    HERDR_CAFFEINATE_BIN="$T/bin/caffeinate" \
    HERDR_CAFFEINATED_SERVER_PID="${SERVER:-$SERVER_PID}" \
    HERDR_SOCKET_PATH="$socket" \
    HERDR_PLUGIN_STATE_DIR="$T/state" \
    HERDR_PLUGIN_CONFIG_DIR="$T/config" \
    HERDR_TEST_STATUS_FILE="$T/status" \
    sh "$SCRIPT" "$@" >/dev/null
}

set_status() { printf '%s\n' "$1" >"$T/status"; }
count() { pgrep -f "$T/bin/caffeinate" | wc -l | tr -d ' '; }

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (want $3, got $2)"
    FAILED=1
  fi
}

set_status working
run reconcile
check "working agent starts caffeinate" "$(count)" 1
pgrep -fl "$T/bin/caffeinate" | grep -q -- "-ims -w $SERVER_PID$"
check "caffeinate waits on the server pid" $? 0

run reconcile
check "repeat reconcile does not duplicate" "$(count)" 1

set_status blocked
run reconcile
check "idle keeps caffeinate during grace" "$(count)" 1
sleep 2.5
check "idle releases after grace" "$(count)" 0

set_status working
run reconcile
set_status idle
run reconcile
set_status working
run reconcile
sleep 2.5
check "work during grace cancels release" "$(count)" 1

set_status down
run reconcile
check "unreachable server keeps state" "$(count)" 1

set_status working
run stop
check "pause releases" "$(count)" 0
run reconcile
check "paused ignores working agents" "$(count)" 0
run toggle
check "toggle resumes" "$(count)" 1

SOCKET="$T/b.sock" run reconcile
check "second session gets its own caffeinate" "$(count)" 2
SOCKET="$T/b.sock" run stop
check "pausing one session leaves the other" "$(count)" 1
SOCKET="$T/b.sock" run start

sleep 600 &
other=$!
SERVER=$other SOCKET="$T/c.sock" run reconcile
check "third session running" "$(count)" 3
kill "$other"
sleep 0.5
check "server exit releases its caffeinate" "$(count)" 2

set_status hung
start=$(date +%s)
run reconcile
check "hung server request times out" "$(($(date +%s) - start <= 3))" 1

exit "$FAILED"
