#!/bin/bash
# task-set.sh <task-dir> <field> <value>
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 3 ] || die 2 "usage: task-set.sh <task-dir> <field> <value>"
dir=$1 f=$2 v=$3
task_dir "$dir"
case "$v" in *$'\n'*) die 2 "value must be one line" ;; esac
case "$f" in
  title|complexity_reason|waiting_on|repositories|merge_requests) ;;
  status) case "$v" in open|closed) ;; *) die 2 "status must be open or closed" ;; esac ;;
  stage) case "$v" in intake|align|build|review|demo|developer-review|ship|watch|cleanup|done) ;;
           *) die 2 "unknown stage '$v'" ;; esac ;;
  complexity) case "$v" in unknown|trivial|simple|complex) ;; *) die 2 "complexity must be unknown, trivial, simple or complex" ;; esac ;;
  needs_developer|hold_merge|review_slot) case "$v" in yes|no) ;; *) die 2 "$f must be yes or no" ;; esac ;;
  *) die 2 "unknown field '$f'" ;;
esac
lock=$dir/.task.lock tmp=""
trap 'rm -f "$tmp"; lock_drop "$lock"' EXIT
lock_take "$lock"
tmp=$(mktemp "$dir/.task.XXXXXX") || die 1 "cannot write in $dir"
# The value travels through the environment so awk does not interpret backslashes in it.
F=$f V=$v awk 'BEGIN{f=ENVIRON["F"]; v=ENVIRON["V"]}
  NR>1 && /^---$/ { fm=1 } !fm && !done && (index($0, f": ")==1 || $0==f":") { print (v=="" ? f":" : f": "v); done=1; next } {print}
  END { exit done ? 0 : 3 }' "$dir/task.md" > "$tmp" \
  || { rm -f "$tmp"; die 1 "task.md has no '$f' line: nothing was set"; }
mv "$tmp" "$dir/task.md"
