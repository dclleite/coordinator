#!/bin/bash
# sweep.sh <task-dir> [--confirmed]   stops what the task recorded and is still alive
# sweep.sh --orphans [--json]         lists what is alive or on disk that no open task owns; stops nothing
# sweep.sh --readings                 kind, count, limit, state per resource row (health.sh reads this)
# sweep.sh --run <kind> count|list|limit|class|stop [<id>]
# sweep.sh --worktrees                worktrees recorded in any task that still exist on disk
set -u
. "$(dirname "$0")/lib.sh"
set -a; . "$ROOT/config/health.conf"; set +a
export ROOT DATA SCRIPTS
TIMEOUT=${RES_TIMEOUT_SEC:-10}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=10 ;; esac
CTIMEOUT=${CONTAINER_TIMEOUT_SEC:-3}
case "$CTIMEOUT" in ''|*[!0-9]*) CTIMEOUT=3 ;; esac
KIND=""

# Tracked rows first; a DATA row of the same kind replaces the tracked one in place.
table() {
  local f files=()
  for f in "$ROOT/config/resources.tsv" "$DATA/config/resources.tsv"; do [ -f "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || return 0
  awk -F'\t' '!/^#/ && NF>=6 && $1!="" {
      if (!($1 in row)) order[++n]=$1
      row[$1]=$0 }
    END { for (i=1; i<=n; i++) print row[order[i]] }' \
    "${files[@]}"
}
row_of() { table | awk -F'\t' -v k="$1" '$1==k' | head -1; }

# run_cmd <command> [<id>]: runs a table command within the limit of its kind; output on stdout, its exit code returned.
run_cmd() {
  local cmd=$1
  [ "$cmd" != "-" ] || return 3
  cmd=${cmd//\{id\}/\"\$RES_ID\"}
  (cd "$ROOT" && run_limited "$(limit_of "$KIND")" env RES_ID="${2:-}" bash -o pipefail -c "$cmd")
}
# A container engine that does not answer must not hold every reading for the long limit.
limit_of() { if [ "$1" = containers ]; then echo "$CTIMEOUT"; else echo "$TIMEOUT"; fi; }

count_of() { # prints a whole number or unknown
  local n
  n=$(run_cmd "$1" | tr -d ' \t\r' | head -1) || { echo unknown; return; }
  case "$n" in ''|*[!0-9]*) echo unknown ;; *) echo "$n" ;; esac
}
state_of() { # <count> <limit>
  if [ "$1" = unknown ]; then echo unknown
  elif [ "$2" != "-" ] && [ "$1" -gt "$2" ] 2>/dev/null; then echo HIGH
  else echo ok; fi
}

open_tasks() {
  local t
  for t in "$DATA"/tasks/*/*/task.md; do
    [ -f "$t" ] && [ "$(field "$t" status)" = open ] && dirname "$t"
  done
}
# Ids of <kind> that an open task owns: its open resources.tsv rows, plus the related records below.
owned_ids() {
  local kind=$1 d
  open_tasks | while IFS= read -r d; do
    [ -f "$d/resources.tsv" ] && awk -F'\t' -v k="$kind" \
      '($1==k || (k=="browser-profiles" && $1=="browsers")) && $5=="-" {print $2}' "$d/resources.tsv"
    [ "$kind" = worktrees ] && [ -f "$d/agents.tsv" ] && awk -F'\t' '$6!="-" && $6!="" {print $6}' "$d/agents.tsv"
  done
}
protected() { # service.sh protected threads|paths, one per line; absent service.sh protects nothing
  local svc=${COORD_SERVICE_SH:-$SCRIPTS/service.sh}
  [ -x "$svc" ] || return 0
  "$svc" protected "$1" 2>/dev/null | tr ',' '\n' | sed '/^$/d'
}
is_protected() { # <id> <owner>
  local p
  while IFS= read -r p; do
    case "$p" in *'*') case "$1" in "${p%\*}"*) return 0 ;; esac ;; *) [ "$1" = "$p" ] && return 0 ;; esac
  done <<< "$PROT_PATHS"
  [ -n "${2:-}" ] && [ "$2" != "-" ] && grep -qxF -- "$2" <<< "$PROT_THREADS"
}
load_protected() { PROT_PATHS=$(protected paths); PROT_THREADS=$(protected threads); }

case "${1:-}" in
--readings)
  table | while IFS= read -r line; do
    split_row "$line"; KIND=$F1; c=$(count_of "$F2")
    printf '%s\t%s\t%s\t%s\n' "$F1" "$c" "$F3" "$(state_of "$c" "$F3")"
  done ;;

--run)
  [ $# -ge 3 ] || die 2 "usage: sweep.sh --run <kind> count|list|limit|class|stop [<id>]"
  line=$(row_of "$2"); [ -n "$line" ] || die 2 "no resource row for kind: $2"
  split_row "$line"; KIND=$F1
  case "$3" in
    count) count_of "$F2" ;;
    list) [ "$F4" != "-" ] || die 1 "$2 cannot be listed"; run_cmd "$F4" ;;
    limit) echo "$F3" ;;
    class) echo "$F6" ;;
    stop) [ $# -eq 4 ] || die 2 "usage: sweep.sh --run <kind> stop <id>"
          [ "$F5" != "-" ] || die 1 "$2 has no stop command"; run_cmd "$F5" "$4" ;;
    *) die 2 "unknown action: $3" ;;
  esac ;;

--worktrees)
  for d in "$DATA"/tasks/*/*/; do
    [ -f "$d/agents.tsv" ] && awk -F'\t' '$6!="-" && $6!="" {print $6}' "$d/agents.tsv"
    [ -f "$d/resources.tsv" ] && awk -F'\t' '$1=="worktrees" && $5=="-" {print $2}' "$d/resources.tsv"
  done | sort -u | while IFS= read -r wt; do [ -d "$wt" ] && echo "$wt"; done ;;

--orphans)
  json=0; [ "${2:-}" = --json ] && json=1
  load_protected; first=1; found=0
  [ $json -eq 1 ] && printf '['
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    split_row "$line"; kind=$F1 limit=$F3 list=$F4 KIND=$F1
    c=$(count_of "$F2"); st=$(state_of "$c" "$limit"); ids=""
    if [ "$list" != "-" ] && all=$(run_cmd "$list"); then
      owned=$(owned_ids "$kind")
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        grep -qxF -- "$id" <<< "$owned" && continue
        is_protected "$id" && continue
        ids=${ids:+$ids$'\n'}$id
      done <<< "$all"
    fi
    if [ $json -eq 1 ]; then
      [ $first -eq 1 ] || printf ','; first=0
      printf '{"kind":%s,"count":%s,"limit":%s,"state":%s,"orphans":[' \
        "$(json_str "$kind")" "$(json_str "$c")" "$(json_str "$limit")" "$(json_str "$st")"
      sep=""
      while IFS= read -r id; do [ -n "$id" ] && printf '%s%s' "$sep" "$(json_str "$id")" && sep=,; done <<< "$ids"
      printf ']}'
    else
      while IFS= read -r id; do [ -n "$id" ] && printf '%s\t%s\n' "$kind" "$id" && found=1; done <<< "$ids"
    fi
  done <<< "$(table)"
  if [ $json -eq 1 ]; then printf ']\n'; elif [ $found -eq 0 ]; then echo "nothing orphaned"; fi ;;

-*|'') die 2 "usage: sweep.sh <task-dir> [--confirmed] | --orphans [--json] | --readings | --run <kind> <action> | --worktrees" ;;

*)
  task_dir "$1"; dir=$1; confirmed=0; [ "${2:-}" = --confirmed ] && confirmed=1
  rec=$dir/resources.tsv
  [ -f "$rec" ] || { echo "nothing recorded"; exit 0; }
  load_protected; failed=0
  rows=$(awk -F'\t' '$5=="-" {print $1 "\t" $2 "\t" $3}' "$rec")
  [ -n "$rows" ] || { echo "nothing open"; exit 0; }
  while IFS= read -r r; do
    split_row "$r"; kind=$F1 id=$F2 owner=$F3
    line=$(row_of "$kind")
    if [ -z "$line" ]; then echo "$kind $id: kept, no resource row for this kind"; continue; fi
    split_row "$line"; list=$F4 stop=$F5 class=$F6 KIND=$kind
    if is_protected "$id" "$owner"; then echo "$kind $id: kept, protected by a service"; continue; fi
    alive=unknown
    if [ "$list" != "-" ] && all=$(run_cmd "$list"); then
      if grep -qxF -- "$id" <<< "$all"; then alive=yes; else alive=no; fi
    fi
    if [ $alive = no ]; then "$SCRIPTS/resource-done.sh" "$dir" "$kind" "$id" >/dev/null; echo "$kind $id: already gone"; continue; fi
    if [ "$class" = confirm ] && [ $confirmed -eq 0 ]; then echo "$kind $id: kept, needs --confirmed"; continue; fi
    if [ "$stop" = "-" ]; then echo "$kind $id: kept, no stop command"; continue; fi
    if run_cmd "$stop" "$id" >/dev/null; then
      "$SCRIPTS/resource-done.sh" "$dir" "$kind" "$id" >/dev/null; echo "$kind $id: stopped"
    else echo "$kind $id: stop failed"; failed=1; fi
  done <<< "$rows"
  exit $failed ;;
esac
