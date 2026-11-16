#!/bin/bash
# worktree-cleanup.sh <task-dir>  ->  removes the task's safe worktrees; queues the ones git refuses to remove
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 1 ] || die 2 "usage: worktree-cleanup.sh <task-dir>"
task_dir "$1"
self=$(physical "$1")
queue=$DATA/tasks/cleanup-pending.tsv
. "$SCRIPTS/worktree-rules.sh"
removed=0; queued=0; kept=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  split_row "$line"; repo=${F5:-} wt=${F6:-} sha=${F9:-}
  [ "$wt" != "-" ] || continue
  if [ -z "$repo" ] || [ -z "$wt" ]; then echo "kept: malformed row in agents.tsv"; kept=$((kept+1)); continue; fi
  if reason=$(keep_reason "$repo" "$wt" "$1"); then echo "kept $wt: $reason"; kept=$((kept+1)); continue; fi
  if ! reason=$(worktree_removable "$repo" "$wt" "$sha"); then
    echo "kept $wt: $reason"; kept=$((kept+1)); continue
  fi
  rid=$(made_record "$(physical "$wt")" "$1")
  # Never --force: git itself refuses anything the checks above missed.
  if git -C "$repo" worktree remove "$(physical "$wt")" 2>/dev/null; then
    "$SCRIPTS/resource-done.sh" "$1" worktrees "$rid" >/dev/null
    echo "removed $wt"; removed=$((removed+1))
  else
    row=$(printf '%s\t%s\t%s\t%s' "$repo" "$wt" "$sha" "${self#"$(physical "$DATA")"/}")
    grep -qxF "$row" "$queue" 2>/dev/null || printf '%s\n' "$row" >> "$queue"
    echo "queued $wt: removal refused, retry with scripts/cleanup-pending.sh"; queued=$((queued+1))
  fi
done < "$1/agents.tsv"
echo "removed=$removed queued=$queued kept=$kept"
