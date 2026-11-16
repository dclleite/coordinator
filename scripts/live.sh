#!/bin/bash
# live.sh <thread-id>  ->  one word: the runtime's state for that thread, or unknown
# live.sh pid:<n>      ->  running or ended (an agent started by dispatch.sh launch)
# live.sh --stop pid:<n>  stops that agent's process group, only while it is still that agent
# live.sh --mark <task-dir> pid:<n>  saves the start time of an agent started by hand, so the two above know it
set -u
. "$(dirname "$0")/lib.sh"
if [ "${1:-}" = --mark ]; then
  [ $# -eq 3 ] || die 2 "usage: live.sh --mark <task-dir> pid:<n>"
  task_dir "$2"
  case "$3" in pid:*) n=${3#pid:} ;; *) die 2 "not a process id: $3" ;; esac
  case "$n" in ''|*[!0-9]*|0*|1) die 2 "not a process id: $3" ;; esac
  start=$(proc_start "$n"); [ -n "$start" ] || die 1 "no process $n"
  # A mark lets the sweep stop the whole group, so a wrong id copied from a log must not pass.
  [ "$(ps -o uid= -p "$n" 2>/dev/null | tr -d ' ')" = "$(id -u)" ] || die 1 "refused: process $n belongs to another user"
  age=$(ps -o etime= -p "$n" 2>/dev/null | awk '{ d = 0; t = $1; if (index(t, "-")) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
    k = split(t, a, ":"); s = 0; for (i = 1; i <= k; i++) s = s * 60 + a[i]; print d * 86400 + s }')
  max=${MARK_MAX_AGE_SEC:-60}
  [ -n "$age" ] && [ "$age" -le "$max" ] ||
    die 1 "refused: process $n started ${age:-?}s ago; mark an agent within ${max}s of starting it"
  self=$(physical "$2")
  for f in "$DATA"/tasks/*/*/runs/*.start; do
    [ -f "$f" ] || continue
    d=$(physical "${f%/runs/*}"); [ "$d" != "$self" ] || continue
    if N=$n S=$start awk -F'\t' '$1==ENVIRON["N"] && $2==ENVIRON["S"] {f=1} END {exit !f}' "$f"; then
      die 1 "refused: pid:$n is already recorded by ${d#"$(physical "$DATA/tasks")"/}"
    fi
  done
  mkdir -p "$2/runs" && printf '%s\t%s\n' "$n" "$start" > "$2/runs/pid-$n.start" || die 1 "cannot write in $2/runs"
  echo "marked: pid:$n"; exit 0
fi
if [ "${1:-}" = --stop ]; then
  [ $# -eq 2 ] || die 2 "usage: live.sh --stop pid:<n>"
  case "$2" in pid:*) n=${2#pid:} ;; *) die 2 "not a process id: $2" ;; esac
  agent_run_ours "$n" || die 1 "not stopped: $2 is not a running agent of this coordinator"
  kill -TERM -- "-$n"
  exit
fi
[ $# -eq 1 ] && [ -n "$1" ] || die 2 "usage: live.sh <thread-id>"
case "$1" in
  pid:*)
    n=${1#pid:}
    case "$n" in ''|*[!0-9]*) die 2 "not a process id: $1" ;; esac
    if agent_run_ours "$n"; then echo running; else echo ended; fi
    exit 0 ;;
esac
# COORD_T3 names the runtime command (tests point it at a fake, or at nothing).
if [ -n "${COORD_T3+x}" ]; then t3=$COORD_T3
else t3=$(tool_path t3) || t3=""; fi
[ -n "$t3" ] && [ -x "$t3" ] || { echo unknown; exit 0; }
secs=${LIVE_TIMEOUT_SEC:-5}
if command -v timeout >/dev/null 2>&1; then run=(timeout "$secs")
elif command -v gtimeout >/dev/null 2>&1; then run=(gtimeout "$secs")
elif command -v perl >/dev/null 2>&1; then run=(perl -e 'alarm shift @ARGV; exec @ARGV' "$secs")
else run=(env); fi
out=$("${run[@]}" "$t3" thread show --messages 0 --json "$1" </dev/null 2>/dev/null) || out=""
# The thread object comes first, so its status is the first "status" key in the answer.
state=$(printf '%s' "$out" | tr -d '\n' | grep -o '"status": *"[A-Za-z_-]*"' | head -1 | sed 's/.*"\([A-Za-z_-]*\)"$/\1/')
echo "${state:-unknown}"
