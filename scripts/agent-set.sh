#!/bin/bash
# agent-set.sh <task-dir> <thread-id> worktree|branch|mr_sha|parent|state <value>
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 4 ] || die 2 "usage: agent-set.sh <task-dir> <thread-id> worktree|branch|mr_sha|parent|state <value>"
dir=$1 thread=$2 col=$3 val=$4
task_dir "$dir"
case "$col" in
  worktree) n=6 ;; branch) n=7 ;; mr_sha) n=9 ;; parent) n=10 ;; state) n=11 ;;
  *) die 2 "column must be worktree, branch, mr_sha, parent or state" ;;
esac
case "$val" in ''|*$'\t'*|*$'\n'*) die 2 "value must not be empty or contain tabs or newlines" ;; esac
if [ "$col" = state ]; then
  case "$val" in running|waiting|done|failed|stopped) ;; *) die 2 "state must be running, waiting, done, failed or stopped" ;; esac
fi
lock=$dir/.agents.lock tmp=""
trap 'rm -f "$tmp"; lock_drop "$lock"' EXIT
lock_take "$lock"
provider=$(T=$thread awk -F'\t' '$8""==ENVIRON["T"] {print $2; exit}' "$dir/agents.tsv")
[ -n "$provider" ] || die 1 "no agent with thread id '$thread' on this task"
if [ "$col" = worktree ] && [ "$val" != "-" ]; then "$SCRIPTS/route.sh" check "$provider" "$val" || exit 1; fi
tmp=$(mktemp "$dir/.agents.XXXXXX") || die 1 "cannot write in $dir"
# A row written before parent and state gets their defaults when it is rewritten.
T=$thread V=$val awk -F'\t' -v OFS='\t' -v n="$n" '$8""==ENVIRON["T"] {
    if (NF < 10) $10="-"; if (NF < 11) $11="unknown"; $n=ENVIRON["V"] } {print}' \
  "$dir/agents.tsv" > "$tmp" && mv "$tmp" "$dir/agents.tsv"
