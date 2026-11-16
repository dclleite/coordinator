#!/bin/bash
# hold.sh on|off <task-dir>  |  hold.sh on|off --all  |  hold.sh may-merge <task-dir>
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 2 ] || die 2 "usage: hold.sh on|off <task-dir>|--all | hold.sh may-merge <task-dir>"
global=$DATA/tasks/HOLD_MERGE
case "$1" in
  on|off)
    if [ "$2" = "--all" ]; then
      if [ "$1" = on ]; then now > "$global"; else rm -f "$global"; fi
      for t in "$DATA"/tasks/*/*/task.md; do
        [ -f "$t" ] && [ "$(field "$t" status)" = open ] || continue
        "$SCRIPTS/ledger.sh" "$(dirname "$t")" hold "global merge hold $1"
      done
    else
      task_dir "$2"
      if [ "$1" = on ]; then v=yes; else v=no; fi
      "$SCRIPTS/task-set.sh" "$2" hold_merge "$v" && "$SCRIPTS/ledger.sh" "$2" hold "merge hold $1"
    fi ;;
  may-merge)
    task_dir "$2"
    [ ! -e "$global" ] || die 1 "held: the global merge hold is on"
    # Fails closed: only an exact "no" allows a merge.
    [ "$(field "$2/task.md" hold_merge)" = no ] || die 1 "held: hold_merge of this task is not 'no'"
    ;;
  *) die 2 "usage: hold.sh on|off <task-dir>|--all | hold.sh may-merge <task-dir>" ;;
esac
