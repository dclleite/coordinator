#!/bin/bash
# resource-done.sh <task-dir> <kind> <id>  ->  marks a recorded resource as stopped
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 3 ] || die 2 "usage: resource-done.sh <task-dir> <kind> <id>"
task_dir "$1"
rec=$1/resources.tsv lock=$1/.resources.lock tmp=""
[ -f "$rec" ] || die 1 "nothing recorded in $1"
trap 'rm -f "$tmp"; lock_drop "$lock"' EXIT
lock_take "$lock"
tmp=$(mktemp "$rec.XXXXXX")
if K=$2 I=$3 T=$(now) awk -F'\t' -v OFS='\t' '
    $1""==ENVIRON["K"] && $2""==ENVIRON["I"] && $5=="-" {$5=ENVIRON["T"]; f=1} {print}
    END {exit !f}' "$rec" > "$tmp"; then
  mv "$tmp" "$rec"; echo "stopped: $2 $3"
else rm -f "$tmp"; die 1 "no open record: $2 $3"; fi
