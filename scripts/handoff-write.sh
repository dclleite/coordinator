#!/bin/bash
# handoff-write.sh <task-dir> <from> <to>   (body on stdin)  ->  prints the handoff path
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 3 ] || die 2 "usage: handoff-write.sh <task-dir> <from> <to> < body"
dir=$1 from=$2 to=$3
task_dir "$dir"
[[ "$from" =~ ^[a-z0-9-]+$ && "$to" =~ ^[a-z0-9-]+$ ]] || die 2 "from and to must be lowercase letters, digits and dashes"
mkdir -p "$dir/handoffs"
tmp=$(mktemp "$dir/.handoff.XXXXXX") || die 1 "cannot write in $dir"
lock=$DATA/.inbox.lock
# Until the inbox has its line, a failure removes the claim and the file, so a retry starts clean.
written=0
trap 'rm -f "$tmp" "${out:-}"; [ "$written" = 1 ] || rm -f "${claim:-}" "${file:-}"; lock_drop "$lock"' EXIT
cat > "$tmp"
[ -s "$tmp" ] || die 2 "empty handoff"
"$SCRIPTS/secret-scan.sh" "$tmp" >&2 || die 1 "handoff not written: it contains what looks like a secret"

# The number is claimed with an exclusive create, so two writers never take the same one.
last=$(ls -a "$dir/handoffs" | sed -n -e 's/^\([0-9][0-9]*\)-.*/\1/p' -e 's/^\.claim-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)
n=$(( 10#${last:-0} + 1 ))
until ( set -C; : > "$dir/handoffs/.claim-$(printf '%02d' "$n")" ) 2>/dev/null; do n=$((n + 1)); done
claim=$dir/handoffs/.claim-$(printf '%02d' "$n")
n=$(printf '%02d' "$n")
out=$(mktemp "$dir/handoffs/.writing.XXXXXX") || die 1 "cannot write in $dir/handoffs"
{
  echo "---"; echo "from: $from"; echo "to: $to"; echo "task: $(basename "$dir")"; echo "written: $(now)"; echo "---"; echo
  cat "$tmp"
} > "$out" || die 1 "handoff not written"

# report.sh rewrites the inbox under the same lock; an append outside it could be lost.
[ "$to" != coordinator ] || lock_take "$lock"
file=$dir/handoffs/$n-$from-to-$to.md
mv "$out" "$file" || die 1 "handoff not written: $file"
if [ "$to" = coordinator ]; then
  real=$(physical "$dir"); data=$(physical "$DATA")
  rel=${real#"$data"/}
  printf '%s\t%s\t%s\t%s\t0\n' "$(now)" "$rel" "$(basename "$file")" "$from" >> "$DATA/inbox.tsv" ||
    die 1 "handoff not written: no inbox line"
  lock_drop "$lock"
fi
written=1
echo "$file"
