#!/bin/bash
# brief-check.sh <task-dir> <brief-file>  ->  exit 0 when the request block equals request.md
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 2 ] || die 2 "usage: brief-check.sh <task-dir> <brief-file>"
dir=$1 brief=$2
task_dir "$dir"
[ -f "$brief" ] || die 2 "brief not found: $brief"
export LC_ALL=C
begin=$(sed -n '4p' "$brief")
[[ "$begin" =~ ^=====BEGIN\ DEVELOPER\ REQUEST\ ([0-9a-f]{16})\ sha256=([0-9a-f]{64})=====$ ]] \
  || die 1 "mismatch: line 4 of the brief is not the request marker"
id=${BASH_REMATCH[1]} hash=${BASH_REMATCH[2]}
end=$(grep -nxF "=====END DEVELOPER REQUEST $id=====" "$brief" | head -1 | cut -d: -f1)
[ -n "$end" ] || die 1 "mismatch: closing request marker not found"
block=$(mktemp "$dir/.brief-block.XXXXXX") || die 1 "cannot write in $dir"
trap 'rm -f "$block"' EXIT
tail -n +5 "$brief" | head -n $((end - 5)) > "$block"
if ! diff=$(cmp "$block" "$dir/request.md" 2>&1); then
  line=$(printf '%s' "$diff" | sed -n 's/.*line \([0-9][0-9]*\).*/\1/p')
  die 1 "mismatch: request block differs from request.md${line:+ at line $line}"
fi
now_hash=$(sha256 < "$dir/request.md") || exit 2
[ "$now_hash" = "$hash" ] || die 1 "mismatch: hash in the marker is not the hash of request.md"
