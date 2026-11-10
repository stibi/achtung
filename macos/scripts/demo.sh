#!/usr/bin/env bash
# Starts Achtung in demo mode: a Debug build of the working tree (run.sh) talking to a fake
# server with made-up alerts (demo-server.py), for showing the app or recording it. Real
# alerts and the stored server address stay untouched: the address is a launch argument,
# and the demo's read state lives under its own key, written fresh here so the demo starts
# with something unread, and removed when the app quits. So does its saved notification
# state (ADR 0018): the demo server's clock starts afresh each time, so a saved one would
# announce the made-up history as new.
set -euo pipefail

cd "$(dirname "$0")"
port=8790
address="http://127.0.0.1:$port"
bundle=io.github.stibi.achtung
read_state_key="readState $address"
notifications_key="notificationState $address"

# Something else on the port (an orphaned demo server, with its clock long past) would
# answer in its place.
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null; then
  echo "Port $port is in use, so the demo server can't start: lsof -nP -iTCP:$port" >&2
  exit 1
fi

quit_achtung() {
  if pgrep -xq Achtung; then
    osascript -e "tell application id \"$bundle\" to quit" >/dev/null
    for _ in {1..50}; do pgrep -xq Achtung || break; sleep 0.1; done
  fi
}
# A running Achtung first: one left from an earlier demo would save its read state over
# the fresh one below as it quits.
quit_achtung
defaults delete "$bundle" "$notifications_key" 2>/dev/null || true

python3 -I demo-server.py "$port" &
server=$!
# Ends the demo however the script stops, Ctrl-C included: the app first, so it can't write
# the demo's read state back after it's deleted.
cleanup() {
  quit_achtung
  kill "$server" 2>/dev/null || true
  defaults delete "$bundle" "$read_state_key" 2>/dev/null || true
  defaults delete "$bundle" "$notifications_key" 2>/dev/null || true
}
trap cleanup EXIT
for _ in {1..50}; do curl -fsS "$address/api/channels" >/dev/null 2>&1 && break; sleep 0.1; done
if ! curl -fsS "$address/api/channels" >/dev/null 2>&1; then
  echo "The demo server didn't start." >&2
  exit 1
fi

# Read up to 8 hours ago, back from a visit 90 minutes ago (the "new" divider), and two
# alerts since opened. Dates are seconds since 2001, as JSONEncoder writes them.
python3 -I - "$bundle" "$read_state_key" <<'PY'
import datetime, json, subprocess, sys
now = datetime.datetime.now(datetime.timezone.utc)
since_2001 = lambda hours: (now - datetime.timedelta(hours=hours)
                            - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()
state = {
    "readUpTo": {"6": since_2001(0), "17": since_2001(0)},
    "channelSeenUpTo": [],
    "seenUntil": since_2001(1.5),
    "baseline": since_2001(8),
}
subprocess.run(["defaults", "write", sys.argv[1], sys.argv[2], "-data",
                json.dumps(state).encode().hex()], check=True)
PY

./run.sh -serverAddress "$address" "$@"
echo "Demo server on $address. A critical alert fires in 45 seconds, another resolves"
echo "after 2.5 minutes. Quit Achtung to end the demo."
sleep 3
while pgrep -xq Achtung; do sleep 1; done
trap - EXIT
kill "$server" 2>/dev/null || true
defaults delete "$bundle" "$read_state_key" 2>/dev/null || true
defaults delete "$bundle" "$notifications_key" 2>/dev/null || true
