#!/bin/bash
# model.sh <provider> <tier>  ->  model<TAB>effort
set -u
. "$(dirname "$0")/lib.sh"
[ $# -eq 2 ] || die 2 "usage: model.sh <provider> <tier>"

# The row for provider and tier: the local override first, then the tracked table.
row() {
  local f
  for f in "$DATA/config/models.tsv" "$ROOT/config/models.tsv"; do
    [ -f "$f" ] || continue
    P=$1 T=$2 awk -F'\t' '$1==ENVIRON["P"] && $2==ENVIRON["T"] { print $3"\t"$4"\t"$5; found=1; exit }
      END { exit !found }' "$f" && return 0
  done
  return 1
}

step_up() {
  case "$1" in low) echo medium ;; medium) echo high ;; high) echo xhigh ;; xhigh) echo max ;; *) echo "$1" ;; esac
}

nomodel="no model for provider '$1' tier '$2' in config/models.tsv"
untuned=""
if ! r=$(row "$1" "$2"); then
  # A provider nobody tuned: escalated is default one effort step up, planning falls back to escalated.
  case "$2" in escalated|planning) ;; *) die 2 "$nomodel" ;; esac
  if [ "$2" = planning ] && r=$(row "$1" escalated); then untuned="planning falls back to escalated"
  elif r=$(row "$1" default); then
    r="$(printf '%s' "$r" | cut -f1)	$(step_up "$(printf '%s' "$r" | cut -f2)")	"
    untuned="derived from default"
  else die 2 "$nomodel"; fi
fi
[ "$(printf '%s' "$r" | cut -f3)" = untuned ] && untuned=${untuned:-marked untuned}
[ -z "$untuned" ] || echo "warning: $1 $2 is untuned ($untuned)" >&2
case "$2" in default|escalated) ;; *) echo "warning: tier $2 needs the developer's explicit word for this launch, in this conversation" >&2 ;; esac
printf '%s\n' "$r" | cut -f1,2
