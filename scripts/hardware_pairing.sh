#!/usr/bin/env bash
# Pairing checks between this computer and a second one reached over ssh.
#
# The peripheral side runs `ble-hardware-check --peripheral --secure`, the central side
# `ble-hardware-check <address> --pair`. The script answers the prompts of both through their
# `--answers` files, the way a person would: it confirms a code only when both sides show the
# same one, and types the passkey one side displays into the other.
#
#   PEER_SSH="ssh tester@192.0.2.10" PEER_BIN=/home/tester/ble-hardware-check \
#   LOCAL_BIN=zig-out/bin/ble-hardware-check.exe PERIPHERAL_ADDR=AA:BB:CC:DD:EE:FF \
#     scripts/hardware_pairing.sh <central: local|peer> <method> [rounds] [initiator]
#
#   initiator  central (default): the central pairs with `--pair` and reconnects afterwards.
#              peripheral: the central only subscribes (`--await-pair`) and the peripheral
#              pairs, which a Windows peripheral does; a pairing the client starts is answered
#              by Windows' own dialog instead.
#
#   method            central --io      peripheral --io    what happens
#   numeric           keyboarddisplay   keyboarddisplay    both show a code, both confirm
#   justworks         none              keyboarddisplay    no code
#   passkey-central   keyboard          display            peripheral shows, central types
#   passkey-peripheral display          keyboard           central shows, peripheral types
#
#   PERIPHERAL_ADDR    address of the peripheral, or `auto` (default) to find it by its service
#   PERIPHERAL_FORGET  command run on the peripheral's computer after every round to remove the
#                      bond there, e.g. "bluetoothctl remove AA:BB:CC:DD:EE:FF" (optional)
#
# The central removes its own bond with `--unpair` after every round. Both programs CHANGE the
# bond state of both computers; use it only between computers of your own.

set -u
central=${1:?usage: hardware_pairing.sh <local|peer> <method> [rounds]}
method=${2:?method: numeric | justworks | passkey-central | passkey-peripheral}
rounds=${3:-10}
initiator=${4:-central}
[ "$initiator" = central ] && c_mode=--pair || c_mode=--await-pair
: "${PEER_SSH:?set PEER_SSH, e.g. \"ssh user@host\"}"
: "${PEER_BIN:?set PEER_BIN to the path of ble-hardware-check on the peer}"
: "${LOCAL_BIN:?set LOCAL_BIN to the path of ble-hardware-check on this computer}"
addr=${PERIPHERAL_ADDR:-auto}
service=5a1e0001-6f3b-4c52-9d27-1e8b7c4a2f10
protected=5a1e0004-6f3b-4c52-9d27-1e8b7c4a2f10

case $method in
  numeric) c_io=keyboarddisplay; p_io=keyboarddisplay ;;
  justworks) c_io=none; p_io=keyboarddisplay ;;
  passkey-central) c_io=keyboard; p_io=display ;;
  passkey-peripheral) c_io=display; p_io=keyboard ;;
  *) echo "unknown method $method" >&2; exit 2 ;;
esac

work=$(mktemp -d)
peer_dir=$($PEER_SSH 'mktemp -d')
trap 'stop_side c; stop_side p; rm -rf "$work"; $PEER_SSH "rm -rf $peer_dir" 2>/dev/null' EXIT

# Each side (c = central, p = peripheral) is "local" or "peer"; these helpers hide which.
where() { if [ "$1" = c ]; then echo "$central"; elif [ "$central" = local ]; then echo peer; else echo local; fi; }
log_of() { if [ "$(where "$1")" = local ]; then cat "$work/$1.log" 2>/dev/null; else $PEER_SSH "cat $peer_dir/$1.log 2>/dev/null"; fi; }
answer() { if [ "$(where "$1")" = local ]; then printf '%s\n' "$2" >> "$work/$1.ans"; else $PEER_SSH "printf '%s\n' '$2' >> $peer_dir/$1.ans"; fi; }
start_side() { # side, arguments...
  local side=$1; shift
  if [ "$(where "$side")" = local ]; then
    : > "$work/$side.ans"
    "$LOCAL_BIN" "$@" --answers "$work/$side.ans" > "$work/$side.log" 2>&1 &
    echo $! > "$work/$side.pid"
  else
    $PEER_SSH "cd $peer_dir && : > $side.ans && (nohup $PEER_BIN $* --answers $peer_dir/$side.ans > $side.log 2>&1 & echo \$! > $side.pid)"
  fi
}
# Arguments that end in the mode: --answers has to come before it.
start_side_before_mode() { # side, mode, arguments before the mode...
  local side=$1 mode=$2; shift 2
  if [ "$(where "$side")" = local ]; then
    : > "$work/$side.ans"
    "$LOCAL_BIN" "$@" --answers "$work/$side.ans" $mode > "$work/$side.log" 2>&1 &
    echo $! > "$work/$side.pid"
  else
    $PEER_SSH "cd $peer_dir && : > $side.ans && (nohup $PEER_BIN $* --answers $peer_dir/$side.ans $mode > $side.log 2>&1 & echo \$! > $side.pid)"
  fi
}
running() { if [ "$(where "$1")" = local ]; then kill -0 "$(cat "$work/$1.pid" 2>/dev/null)" 2>/dev/null; else $PEER_SSH "kill -0 \$(cat $peer_dir/$1.pid 2>/dev/null) 2>/dev/null"; fi; }
stop_side() { if [ "$(where "$1")" = local ]; then kill "$(cat "$work/$1.pid" 2>/dev/null)" 2>/dev/null; else $PEER_SSH "kill \$(cat $peer_dir/$1.pid 2>/dev/null) 2>/dev/null"; fi; }

# Answers the prompts both logs show so far. Sets code_c / code_p / passkey as they appear.
handled_c=0; handled_p=0
answer_prompts() {
  local side other log prompts count i line
  for side in c p; do
    [ "$side" = c ] && other=p || other=c
    log=$(log_of "$side")
    prompts=$(printf '%s\n' "$log" | grep '^>>> ' || true)
    count=$(printf '%s' "$prompts" | grep -c '^' || true)
    eval "i=\$handled_$side"
    while [ "$i" -lt "$count" ]; do
      line=$(printf '%s\n' "$prompts" | sed -n "$((i + 1))p")
      case $line in
        *"Does the other device show"*)
          eval "code_$side=$(printf '%s' "$line" | grep -o '[0-9]\{6\}')"
          # Numeric comparison is answered below, once both sides show their code.
          [ "$method" = numeric ] || answer "$side" y ;;
        *"Pair without a code"*|*"Allow access to service"*) answer "$side" y ;;
        *"Enter the 6-digit code"*)
          [ -n "${passkey:-}" ] || return
          answer "$side" "$passkey" ;;
        *"Enter "*" on the other device"*) passkey=$(printf '%s' "$line" | grep -o '[0-9]\{6\}') ;;
      esac
      i=$((i + 1))
      eval "handled_$side=$i"
    done
  done
  # Like a person: confirm only when both sides show the same code. If one side stays silent
  # for 20 s the shown code is declined.
  if [ "$method" = numeric ] && [ -z "${confirmed:-}" ]; then
    if [ -n "${code_c:-}" ] && [ -n "${code_p:-}" ]; then
      confirmed=1
      if [ "$code_c" = "$code_p" ]; then answer c y; answer p y; else answer c n; answer p n; fi
    elif [ -n "${code_c:-}${code_p:-}" ]; then
      waited=$((${waited:-0} + 1))
      if [ "$waited" -ge 20 ]; then confirmed=1; answer c n; answer p n; fi
    fi
  fi
}

passed=0
for round in $(seq 1 "$rounds"); do
  unset code_c code_p passkey confirmed waited
  handled_c=0; handled_p=0
  start_side p --peripheral 150 --secure --io "$p_io"
  sleep 6
  start_side_before_mode c $c_mode "$addr" --service "$service" --io "$c_io"
  for _ in $(seq 1 150); do
    running c || break
    answer_prompts
    sleep 1
  done
  answer_prompts
  stop_side c

  c_log=$(log_of c)
  paired=no; readable=no; rebonded=no; same=n/a
  printf '%s\n' "$c_log" | grep -q "^Paired, bond state: bonded" && paired=yes
  # "paired" in hex: the protected characteristic is readable only on an encrypted link.
  printf '%s\n' "$c_log" | grep "$protected" | grep -q "read 706169726564" && readable=yes
  printf '%s\n' "$c_log" | grep -q "^Bond state after the reconnect: bonded" && rebonded=yes
  [ "$initiator" = central ] || rebonded=n/a
  if [ "$method" = numeric ]; then
    [ -n "${code_c:-}" ] && [ "${code_c:-}" = "${code_p:-}" ] && same=yes || same=no
  fi
  verdict=FAIL
  [ $paired = yes ] && [ $readable = yes ] && [ $rebonded != no ] && [ $same != no ] && { verdict=PASS; passed=$((passed + 1)); }
  echo "round $round ($method, central $central, $initiator pairs): paired=$paired protected=$readable bonded-after-reconnect=$rebonded codes-equal=$same code=${code_c:-${passkey:-none}} -> $verdict"
  if [ $verdict = FAIL ]; then
    echo "--- central log"; printf '%s\n' "$c_log" | grep -v '^  notification' | tail -15
    echo "--- peripheral log"; log_of p | grep -v ' s, echo' | tail -8
  fi

  # Remove the bond on both sides so the next round pairs from scratch.
  unpair_addr=$addr
  [ "$unpair_addr" = auto ] && unpair_addr=$(printf '%s\n' "$c_log" | grep -o 'Connecting to [0-9A-F:]*' | tail -1 | cut -d' ' -f3)
  if [ "$central" = local ]; then
    "$LOCAL_BIN" "$unpair_addr" --service "$service" --unpair > "$work/unpair.log" 2>&1
  else
    $PEER_SSH "$PEER_BIN $unpair_addr --service $service --unpair > $peer_dir/unpair.log 2>&1"
  fi
  stop_side p
  if [ -n "${PERIPHERAL_FORGET:-}" ]; then
    if [ "$(where p)" = local ]; then sh -c "$PERIPHERAL_FORGET" > /dev/null 2>&1; else $PEER_SSH "$PERIPHERAL_FORGET" > /dev/null 2>&1; fi
  fi
  sleep 5
done

echo "pairing $method, central $central, $initiator pairs: $passed/$rounds"
[ "$passed" = "$rounds" ]
