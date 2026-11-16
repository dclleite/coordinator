#!/bin/bash
# task-new.sh <scope> <key> <slug> <title>  ->  prints the new task folder
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 4 ] || die 2 "usage: task-new.sh <scope> <KEY-123|-> <slug> <title>"
scope=$1 key=$2 slug=$3 title=$4
cut -f3 "$DATA/config/routing.tsv" 2>/dev/null | grep -qxF -- "$scope" || die 2 "scope must be one from the routing table (third column)"
[[ "$key" == "-" || "$key" =~ ^[A-Z]+-[0-9]+$ ]] || die 2 "key must look like ABC-123, or be -"
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 2 "slug must be lowercase letters, digits and dashes"
case "$title" in *$'\n'*) die 2 "title must be one line" ;; esac
if [ "$key" = "-" ]; then name=$slug; else name=$key-$slug; fi
dir=$DATA/tasks/$scope/$name
[ ! -e "$dir" ] || die 1 "task already exists: $dir"
mkdir -p "$dir/handoffs"
: > "$dir/request.md"; : > "$dir/ledger.md"; : > "$dir/agents.tsv"
{
  echo "---"
  echo "key: $key"
  printf 'title: %s\n' "$title"
  echo "scope: $scope"
  echo "status: open"
  echo "stage: intake"
  echo "complexity: unknown"
  echo "complexity_reason:"
  echo "waiting_on:"
  echo "needs_developer: no"
  echo "hold_merge: no"
  echo "review_slot: no"
  echo "repositories:"
  echo "merge_requests:"
  echo "created: $(now)"
  echo "---"
} > "$dir/task.md"
echo "$dir"
