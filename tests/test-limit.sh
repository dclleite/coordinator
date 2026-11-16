. "$(dirname "$0")/lib.sh"; . "$ROOT/scripts/lib.sh"
# run_limited: a command cut short, or whose caller dies, leaves no process behind.
T=$(mktemp -d "${TMPDIR%/}/coordlim.XXXXXX")
fake() { printf '#!/bin/sh\nsleep %s &\nsleep %s\n' "$2" "$3" > "$T/$1"; chmod +x "$T/$1"; }
# gone <pattern>: true once no process matches, waiting at most three seconds.
gone() { local i=0; while pgrep -f "$1" >/dev/null; do [ $i -lt 30 ] || return 1; sleep 0.1; i=$((i+1)); done; }

eq "output passes through" hi "$(run_limited 5 echo hi)"
fails 3 "exit code passes through" run_limited 5 sh -c 'exit 3'
fake hang 4101 4102
fails 124 "cut at the limit" run_limited 1 "$T/hang"
ok "the command is gone after the limit" gone 'sleep 4102'
ok "its child is gone after the limit" gone 'sleep 4101'
printf '#!/bin/sh\nsleep 4103 &\necho done\n' > "$T/leave"; chmod +x "$T/leave"
eq "a command that returns" done "$(run_limited 5 "$T/leave")"
ok "what it left running is gone" gone 'sleep 4103'
for sig in TERM KILL; do
  n=$([ $sig = TERM ] && echo 51 || echo 52)
  fake "caller-$sig" "4${n}1" "4${n}2"
  bash -c '. "$1"; run_limited 30 "$2"' _ "$ROOT/scripts/lib.sh" "$T/caller-$sig" & c=$!
  i=0; until pgrep -f "sleep 4${n}1" >/dev/null || [ $i -ge 30 ]; do sleep 0.1; i=$((i+1)); done
  kill -"$sig" "$c"; wait "$c" 2>/dev/null
  ok "caller killed with $sig: the command is gone" gone "sleep 4${n}2"
  ok "caller killed with $sig: its child is gone" gone "sleep 4${n}1"
done
rm -rf "$T"
