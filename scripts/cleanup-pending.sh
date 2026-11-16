#!/bin/bash
# cleanup-pending.sh  ->  retries every queued worktree
set -u
. "$(dirname "$0")/lib.sh"
queue=$DATA/tasks/cleanup-pending.tsv
. "$SCRIPTS/worktree-rules.sh"
[ -s "$queue" ] || { echo "removed=0 queued=0 kept=0"; exit 0; }
removed=0; queued=0; kept=0; left=$queue.tmp; : > "$left"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  split_row "$line"; repo=${F1:-} wt=${F2:-} sha=${F3:-} owner=${F4:-}
  if [ -z "$repo" ] || [ -z "$wt" ]; then
    echo "kept: malformed row"; kept=$((kept+1)); printf '%s\n' "$line" >> "$left"; continue
  fi
  if protected "$wt"; then
    echo "kept $wt: protected by a service"; kept=$((kept+1)); printf '%s\n' "$line" >> "$left"; continue
  fi
  if [ ! -e "$wt" ]; then git -C "$repo" worktree prune 2>/dev/null; echo "gone $wt"; removed=$((removed+1)); continue; fi
  if reason=$(keep_reason "$repo" "$wt" "${owner:+$DATA/$owner}"); then
    echo "kept $wt: $reason"; kept=$((kept+1)); printf '%s\n' "$line" >> "$left"; continue
  fi
  if ! reason=$(worktree_removable "$repo" "$wt" "$sha"); then
    echo "kept $wt: $reason"; kept=$((kept+1)); printf '%s\n' "$line" >> "$left"; continue
  fi
  rid=$(made_record "$(physical "$wt")" "$DATA/$owner")
  if git -C "$repo" worktree remove "$(physical "$wt")"; then
    "$SCRIPTS/resource-done.sh" "$DATA/$owner" worktrees "$rid" >/dev/null
    echo "removed $wt"; removed=$((removed+1))
  else queued=$((queued+1)); printf '%s\n' "$line" >> "$left"; fi
done < "$queue"
mv "$left" "$queue"
echo "removed=$removed queued=$queued kept=$kept"
