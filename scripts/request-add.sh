#!/bin/bash
# request-add.sh <task-dir> [--to <addressee>] [--question <text>]   (message on stdin)  ->  prints its number
set -u
. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || die 2 "usage: request-add.sh <task-dir> [--to <addressee>] [--question <text>] < message"
dir=$1; shift
task_dir "$dir"
to=all; question=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) [ $# -ge 2 ] || die 2 "--to needs a value"; to=$2; shift 2 ;;
    --question) [ $# -ge 2 ] || die 2 "--question needs a value"; question=$2; shift 2 ;;
    *) die 2 "unknown option '$1'" ;;
  esac
done
[[ "$to" =~ ^[a-z0-9-]+$ ]] || die 2 "addressee must be lowercase letters, digits and dashes"
# The message stays in a file from start to finish: a shell variable would drop trailing newlines.
tmp=$(mktemp "$dir/.request.XXXXXX") || die 1 "cannot write in $dir"
lock=$dir/.request.lock
trap 'rm -f "$tmp"; lock_drop "$lock"' EXIT
cat > "$tmp"
[ -s "$tmp" ] || die 2 "empty message"
lock_take "$lock"
n=$(( $(cat "$dir/.request-count" 2>/dev/null || echo 0) + 1 ))
nl=""
[ "$(tail -c 1 "$tmp" | od -An -tx1 | tr -d ' \n')" = "0a" ] || nl=" | nl: added"
{
  echo "<!-- msg $n | $(now) | to: $to$nl -->"
  cat "$tmp"
  [ -z "$nl" ] || echo
  echo "<!-- /msg $n -->"
} >> "$dir/request.md"
echo "$n" > "$dir/.request-count"
[ -z "$question" ] || printf 'msg %s: %s\n' "$n" "$(printf '%s' "$question" | tr '\n' ' ')" >> "$dir/questions.md"
echo "$n"
