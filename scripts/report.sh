#!/bin/bash
# report.sh [--peek]  ->  one line per unseen handoff to the coordinator, its "Needs the developer" section, or "nothing new"
set -u
. "$(dirname "$0")/lib.sh"
peek=0
case "${1:-}" in --peek) peek=1 ;; '') ;; *) die 2 "usage: report.sh [--peek]" ;; esac
[ $# -le 1 ] || die 2 "usage: report.sh [--peek]"
inbox=$DATA/inbox.tsv
lock=$DATA/.inbox.lock

# Body lines after the frontmatter.
body() { awk 'NR==1 && $0=="---" { fm=1; next } fm && $0=="---" { fm=0; next } !fm' "$1"; }
needs() { body "$1" | awk '$0=="## Needs the developer" { on=1; print; next } on && /^## / { exit } on' |
  awk '{ l[NR]=$0 } NF { last=NR } END { for (i=1; i<=last; i++) print l[i] }'; }
# The first non-empty line outside the section, without heading marks.
first_line() { body "$1" | awk '$0=="## Needs the developer" { skip=1; next } skip && /^## / { skip=0 }
  !skip && NF { sub(/^#+[ \t]*/, ""); print; exit }'; }

[ -s "$inbox" ] && grep -q $'\t0$' "$inbox" || { echo "nothing new"; exit 0; }
seen=""
trap 'rm -f "$seen"; lock_drop "$lock"' EXIT
[ "$peek" = 1 ] || lock_take "$lock"
seen=$(mktemp "$DATA/.report.XXXXXX") || die 1 "cannot write in $DATA"
shown=0
while IFS= read -r line || [ -n "$line" ]; do
  split_row "$line"
  [ "${F5:-}" = 0 ] || continue
  rel=$F2 file=$F3 from=$F4 dir=$DATA/$F2 h=$DATA/$F2/handoffs/$F3
  printf '%s\t%s\n' "$rel" "$file" >> "$seen"
  shown=$((shown + 1))
  if [ ! -f "$h" ]; then echo "$rel · $from: (handoff not found: $file)"; continue; fi
  if [ -f "$dir/task.md" ]; then
    k=$(field "$dir/task.md" key); [ -n "$k" ] && [ "$k" != "-" ] || k=$(basename "$dir")
  else k=$(basename "$dir"); fi
  echo "$k · $from: $(first_line "$h")"
  section=$(needs "$h")
  [ -z "$section" ] || printf '%s\n' "$section"
  [ "$peek" = 0 ] && [ -f "$dir/task.md" ] || continue
  # The sender's row is done: a sub-coordinator, or a fast worker (a worker the coordinator launched itself).
  case "$from" in sub-coordinator|worker) ;; *) continue ;; esac
  thread=$(R=$from awk -F'\t' '$1==ENVIRON["R"] && (ENVIRON["R"]=="sub-coordinator" || NF<10 || $10=="-") &&
    $11!="failed" && $11!="stopped" { t=$8 } END { print t }' "$dir/agents.tsv" 2>/dev/null)
  [ -z "$thread" ] || "$SCRIPTS/agent-set.sh" "$dir" "$thread" state done >&2
  [ "$from" = sub-coordinator ] && [ -n "$section" ] && "$SCRIPTS/task-set.sh" "$dir" needs_developer yes >&2
done < "$inbox"
[ "$shown" -gt 0 ] || { echo "nothing new"; exit 0; }
[ "$peek" = 0 ] || exit 0
tmp=$(mktemp "$DATA/.inbox.XXXXXX") || die 1 "cannot write in $DATA"
awk -F'\t' -v OFS='\t' 'NR==FNR { s[$1 FS $2]=1; next } $5=="0" && (($2 FS $3) in s) { $5="1" } { print }' \
  "$seen" "$inbox" > "$tmp" && mv "$tmp" "$inbox"
lock_drop "$lock"
"$SCRIPTS/board.sh" >/dev/null 2>&1 || echo "board not rebuilt"
