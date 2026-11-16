#!/bin/bash
# agent-add.sh <task-dir> <role> <provider> <model> <effort> <repo> <worktree> <branch> <thread-id> [<parent>]
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 9 ] || [ $# -eq 10 ] || die 2 "usage: agent-add.sh <task-dir> <role> <provider> <model> <effort> <repo> <worktree> <branch> <thread-id> [<parent>]"
dir=$1; shift
task_dir "$dir"
case "$1" in sub-coordinator|worker|reviewer) ;; *) die 2 "role must be sub-coordinator, worker or reviewer" ;; esac
for a in "$@"; do
  case "$a" in ''|*$'\t'*|*$'\n'*) die 2 "arguments must not be empty or contain tabs or newlines (use - for unknown)" ;; esac
done
parent=${9:--}
"$SCRIPTS/route.sh" check-task "$2" "$dir" || exit 1
"$SCRIPTS/route.sh" check "$2" "$5" || exit 1
[ "$6" = "-" ] || "$SCRIPTS/route.sh" check "$2" "$6" || exit 1
lock=$dir/.agents.lock
trap 'lock_drop "$lock"' EXIT
lock_take "$lock"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\trunning\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$parent" >> "$dir/agents.tsv"
