#!/bin/bash
# ledger.sh <task-dir> <event> <text>
set -u
. "$(dirname "$0")/lib.sh"
events="launch steer escalation decision gate handoff finding hold panel cleanup note"
[ $# -eq 3 ] || die 2 "usage: ledger.sh <task-dir> <event> <text>"
task_dir "$1"
case " $events " in *" $2 "*) ;; *) die 2 "event must be one of: $events" ;; esac
text=$(printf '%s' "$3" | tr '\t\n' '  ')
printf '%s\t%s\t%s\n' "$(now)" "$2" "$text" >> "$1/ledger.md"
