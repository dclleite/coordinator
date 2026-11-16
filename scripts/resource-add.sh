#!/bin/bash
# resource-add.sh <task-dir> <kind> <id> [<owner-thread>]  ->  records something the task started
set -u
. "$(dirname "$0")/lib.sh"
[ $# -ge 3 ] && [ $# -le 4 ] || die 2 "usage: resource-add.sh <task-dir> <kind> <id> [<owner-thread>]"
task_dir "$1"
kind=$2 id=$3 owner=${4:-${T3CODE_THREAD_ID:--}}
for v in "$kind" "$id" "$owner"; do
  case "$v" in ''|*$'\t'*|*$'\n'*) die 2 "kind, id and owner must be non-empty single-line values without tabs" ;; esac
done
[ -n "$("$SCRIPTS/sweep.sh" --run "$kind" limit 2>/dev/null)" ] || die 2 "no resource row for kind: $kind"
rec=$1/resources.tsv lock=$1/.resources.lock
trap 'lock_drop "$lock"' EXIT
lock_take "$lock"
if [ -f "$rec" ] && K=$kind I=$id awk -F'\t' '$1""==ENVIRON["K"] && $2""==ENVIRON["I"] && $5=="-" {f=1} END {exit !f}' "$rec"; then
  echo "already recorded: $kind $id"; exit 0
fi
printf '%s\t%s\t%s\t%s\t-\n' "$kind" "$id" "$owner" "$(now)" >> "$rec"
echo "recorded: $kind $id"
