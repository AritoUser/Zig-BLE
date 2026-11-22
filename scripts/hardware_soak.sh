#!/usr/bin/env bash
# Long-running soak test (B5) between this computer and a second one reached over ssh.
#
# One computer runs `ble-hardware-check --peripheral`, the other `--soak <minutes>`: scan,
# connect, read, subscribe, hold 10 s, disconnect, again and again. Every 10 minutes the
# script records memory and open handles (Windows) or file descriptors (Linux) of both
# processes, so a leak shows as a rising line.
#
#   PEER_SSH="ssh user@linux-host" PEER_BIN=/home/user/ble-hardware-check \
#   LOCAL_BIN=zig-out/bin/ble-hardware-check.exe PERIPHERAL_ADDR=<addr>|auto \
#     scripts/hardware_soak.sh <central: local|peer> <minutes> [log dir]
#
# Logs: <log dir>/central.log, peripheral.log, monitor.log (default zig-out/soak-<time>).

set -u
central=${1:?usage: hardware_soak.sh <local|peer> <minutes> [log dir]}
minutes=${2:?minutes}
logdir=${3:-zig-out/soak-$(date +%Y%m%d-%H%M)}
: "${PEER_SSH:?set PEER_SSH}" "${PEER_BIN:?set PEER_BIN}" "${LOCAL_BIN:?set LOCAL_BIN}"
addr=${PERIPHERAL_ADDR:-auto}
service=5a1e0001-6f3b-4c52-9d27-1e8b7c4a2f10
peer_dir=$(dirname "$PEER_BIN")
# The peripheral outlasts the soak run by 10 minutes.
peripheral_seconds=$(( (minutes + 10) * 60 ))
mkdir -p "$logdir"

local_name=$(basename "$LOCAL_BIN" .exe)
peer_name=$(basename "$PEER_BIN" | cut -c1-15) # pgrep/pkill match the first 15 characters

# Memory and handles of the local process (Windows: working set, handles; else RSS, fds).
local_stats() {
  if command -v powershell.exe > /dev/null; then
    powershell.exe -NoProfile -Command "Get-Process '$local_name' -ErrorAction SilentlyContinue | ForEach-Object { 'pid ' + \$_.Id + ' ws_kb ' + [int](\$_.WorkingSet64/1KB) + ' handles ' + \$_.HandleCount }" | tr -d '\r'
  else
    for pid in $(pgrep -x "$(echo "$local_name" | cut -c1-15)"); do
      echo "pid $pid rss_kb $(awk '/VmRSS/{print $2}' /proc/$pid/status) fds $(ls /proc/$pid/fd | wc -l)"
    done
  fi
}
peer_stats() {
  $PEER_SSH "for pid in \$(pgrep -x $peer_name); do echo \"pid \$pid rss_kb \$(awk '/VmRSS/{print \$2}' /proc/\$pid/status) fds \$(ls /proc/\$pid/fd | wc -l)\"; done"
}

echo "soak: central $central, $minutes min, logs in $logdir"
if [ "$central" = local ]; then
  $PEER_SSH "cd $peer_dir && (nohup $PEER_BIN --peripheral $peripheral_seconds > soak_peripheral.log 2>&1 &)"
  sleep 8
  "$LOCAL_BIN" "$addr" --service "$service" --soak "$minutes" > "$logdir/central.log" 2>&1 &
  run_pid=$!
else
  "$LOCAL_BIN" --peripheral "$peripheral_seconds" > "$logdir/peripheral.log" 2>&1 &
  peripheral_pid=$!
  sleep 8
  $PEER_SSH "cd $peer_dir && $PEER_BIN $addr --service $service --soak $minutes" > "$logdir/central.log" 2>&1 &
  run_pid=$!
fi

while kill -0 "$run_pid" 2> /dev/null; do
  {
    echo "$(date '+%F %T') local:  $(local_stats | tr '\n' ' ')"
    echo "$(date '+%F %T') peer:   $(peer_stats | tr '\n' ' ')"
    echo "$(date '+%F %T') cycles: $(grep -c '^Cycle [0-9]*:' "$logdir/central.log"), last: $(grep '^Cycle [0-9]*:' "$logdir/central.log" | tail -1)"
  } >> "$logdir/monitor.log"
  for _ in $(seq 1 60); do kill -0 "$run_pid" 2> /dev/null || break; sleep 10; done
done
wait "$run_pid"
rc=$?

if [ "$central" = local ]; then
  $PEER_SSH "pkill -x $peer_name; cat $peer_dir/soak_peripheral.log" > "$logdir/peripheral.log" 2>&1
else
  kill "$peripheral_pid" 2> /dev/null
fi
echo "$(date '+%F %T') done, exit $rc" >> "$logdir/monitor.log"
grep -E '^Soak:|^Cycle [0-9]+ failed' "$logdir/central.log" | tail -20
exit $rc
