#!/bin/bash
# board.sh [--live]  ->  rewrites board.md and board.json from the same data
set -u
. "$(dirname "$0")/lib.sh"
case "${1:-}" in --live|'') ;; *) die 2 "usage: board.sh [--live]" ;; esac
[ $# -le 1 ] || die 2 "usage: board.sh [--live]"
live=0; [ "${1:-}" = --live ] && live=1
# COORD_TOOLS is where the optional machine scripts are looked up (tests point it at fakes).
TOOLS=${COORD_TOOLS:-$SCRIPTS}
stale=$(sed -n 's/^STALE_AGENT_MIN=\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$ROOT/config/health.conf" 2>/dev/null | tail -1)
stale=${stale:-120}
mkdir -p "$DATA" || die 1 "cannot write in $DATA"

# ask <open> <close> <script> <args...>: the script's JSON answer, empty when it is missing or answers anything else.
ask() {
  local open=$1 close=$2 s=$TOOLS/$3 out; shift 3
  [ -x "$s" ] || return 0
  out=$(run_limited "${BOARD_ASK_TIMEOUT_SEC:-20}" "$s" "$@")
  out=$(printf '%s' "$out" | awk 'NF' )
  case "$out" in "$open"*"$close") printf '%s' "$out" ;; esac
}

# json_pairs: every scalar of a JSON text as key<TAB>value, in order; a scalar in an array takes the array's key.
json_pairs() {
  LC_ALL=C awk 'BEGIN { RS = "\001" } { s = s $0 }
  function emit(v) { if (key != "") { print key "\t" v; key = "" } else if (st[sp] != "{") print substr(st[sp], 2) "\t" v }
  END {
    n = length(s); i = 1; sp = 0; st[0] = "{"; key = ""
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "{" || c == "[") { st[++sp] = (c == "{") ? "{" : "[" key; key = ""; i++; continue }
      if (c == "}" || c == "]") { if (sp > 0) sp--; key = ""; i++; continue }
      if (c == "\"") {
        v = ""; i++
        while (i <= n) {
          d = substr(s, i, 1)
          if (d == "\\") { e = substr(s, i + 1, 1); i += 2
            if (e == "n" || e == "t" || e == "r") v = v " "; else if (e == "u") { v = v "?"; i += 4 } else v = v e
            continue }
          if (d == "\"") break
          v = v d; i++
        }
        i++; k = i
        while (k <= n && substr(s, k, 1) ~ /[ \t\r\n]/) k++
        if (substr(s, k, 1) == ":") { key = v; i = k + 1 } else emit(v)
        continue
      }
      if (c ~ /[-0-9a-z]/) { v = ""; while (i <= n && substr(s, i, 1) !~ /[,}\] \t\r\n]/) { v = v substr(s, i, 1); i++ }; emit(v); continue }
      i++
    }
  }'
}

j() { json_str "$1"; }
jb() { if [ "$1" = yes ]; then printf true; else printf false; fi; }
name_of() { local k; k=$(field "$1/task.md" key); if [ -n "$k" ] && [ "$k" != "-" ]; then echo "$k"; else basename "$1"; fi; }

health=$(ask '{' '}' health.sh --json)
services=$(ask '[' ']' service.sh status --all --json)
resources=$(ask '[' ']' sweep.sh --orphans --json)
hold_all=no; [ -e "$DATA/tasks/HOLD_MERGE" ] && hold_all=yes

md=$(mktemp "$DATA/.board-md.XXXXXX") || die 1 "cannot write in $DATA"
js=$(mktemp "$DATA/.board-json.XXXXXX") || die 1 "cannot write in $DATA"
parts=$(mktemp -d "$DATA/.board-parts.XXXXXX") || die 1 "cannot write in $DATA"
trap 'rm -rf "$md" "$js" "$parts"' EXIT
: > "$parts/needs"; : > "$parts/running"; : > "$parts/problems"; : > "$parts/problems.json"

# Open tasks, needs-you first, then oldest first.
for t in "$DATA"/tasks/*/*/task.md; do
  [ -f "$t" ] && [ "$(field "$t" status)" = open ] || continue
  if [ "$(field "$t" needs_developer)" = yes ]; then o=0; else o=1; fi
  printf '%s\t%s\t%s\n' "$o" "$(field "$t" created)" "$(dirname "$t")"
done | sort -t$'\t' -k1,1 -k2,2 | cut -f3 > "$parts/order"

problem() { # <kind> <text>
  printf -- '- %s: %s\n' "$1" "$2" >> "$parts/problems"
  printf '{"kind": %s, "text": %s}\n' "$(j "$1")" "$(j "$2")" >> "$parts/problems.json"
}

tasks_json=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  t=$d/task.md; name=$(name_of "$d"); title=$(field "$t" title); stage=$(field "$t" stage)
  needs=$(field "$t" needs_developer); hold=$(field "$t" hold_merge); waiting=$(field "$t" waiting_on)
  if [ "$needs" = yes ]; then
    printf -- '- %s · %s · %s%s\n' "$name" "$title" "$stage" "${waiting:+ · waiting on: $waiting}" >> "$parts/needs"
  fi
  [ "$stage" != done ] || problem stage-done-open "$name: stage is done and status is open"
  recent=$(find "$d/ledger.md" "$d/handoffs" -mmin -"$stale" ! -name '.*' 2>/dev/null | head -1)

  agents_json="" tree=""
  if [ -f "$d/agents.tsv" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      agent_row "$line"
      lv=""
      if [ "$F11" = running ]; then
        [ "$live" = 0 ] || lv=$("$SCRIPTS/live.sh" "$F8" 2>/dev/null || echo unknown)
        [ -n "$recent" ] || problem stale-agent "$name: $F1 $F8 is running with no ledger or handoff activity for $stale minutes"
      fi
      if [ "$F6" != "-" ] && [ -n "$F6" ]; then folder=$(basename "$F6"); else folder=$(basename "$F5"); fi
      text="$F1 · $F2 $F3 $F4 · $folder · $F11${lv:+ (live: $lv)}"
      tree=$tree$(printf '%s\t%s\t%s\t%s' "$F8" "$F10" "$text" "$F11")$'\n'
      a=$(printf '{"role": %s, "provider": %s, "model": %s, "effort": %s, "repo": %s, "worktree": %s, "branch": %s, "thread": %s, "parent": %s, "state": %s, "live": %s}' \
        "$(j "$F1")" "$(j "$F2")" "$(j "$F3")" "$(j "$F4")" "$(j "$F5")" "$(j "$F6")" "$(j "$F7")" "$(j "$F8")" "$(j "$F10")" "$(j "$F11")" "$(j "$lv")")
      agents_json=${agents_json:+$agents_json, }$a
    done < "$d/agents.tsv"
  fi

  {
    printf '\n### %s · %s\n' "$name" "$title"
    printf 'Stage %s%s%s\n\n' "$stage" "$([ "$hold" = yes ] && printf ' · merge hold')" "${waiting:+ · waiting on: $waiting}"
    if [ -z "$tree" ]; then echo "- no agents"
    else
      # A done or stopped agent is counted, not listed, unless an agent still going sits under it.
      printf '%s' "$tree" | awk -F'\t' '
        { th[NR] = $1; pa[NR] = $2; tx[NR] = $3; by[$1] = NR; fin[NR] = ($4 == "done" || $4 == "stopped") }
        function shown(i,   k) { if (i in sh) return sh[i]; sh[i] = !fin[i]
          for (k = 1; k <= NR; k++) if (k != i && pa[k] == th[i] && shown(k)) sh[i] = 1
          return sh[i] }
        function walk(i, dep,   k, p) { if (done[i]++) return; p = ""; for (k = 0; k < dep; k++) p = p "  "
          if (shown(i)) print p "- " tx[i]; else hid++
          for (k = 1; k <= NR; k++) if (k != i && pa[k] == th[i]) walk(k, dep + 1) }
        END { for (i = 1; i <= NR; i++) if (pa[i] == "-" || !(pa[i] in by) || pa[i] == th[i]) walk(i, 0)
              for (i = 1; i <= NR; i++) walk(i, 0)
              if (hid) print "- " hid " more done or stopped (board.json lists them)" }'
    fi
  } >> "$parts/running"

  lh=$(ls "$d/handoffs" 2>/dev/null | grep '^[0-9][0-9]*-.*\.md$' | sort -n | tail -1)
  if [ -n "$lh" ]; then
    hf=$d/handoffs/$lh
    last=$(printf '{"file": %s, "from": %s, "to": %s, "written": %s}' "$(j "$lh")" "$(j "$(field "$hf" from)")" \
      "$(j "$(field "$hf" to)")" "$(j "$(field "$hf" written)")")
  else last='{"file": "", "from": "", "to": "", "written": ""}'; fi

  tj=$(printf '{"key": %s, "dir": %s, "title": %s, "scope": %s, "status": %s, "stage": %s, "complexity": %s, "waiting_on": %s, "needs_developer": %s, "hold_merge": %s, "repositories": %s, "merge_requests": %s, "created": %s,\n   "agents": [%s],\n   "last_handoff": %s}' \
    "$(j "$name")" "$(j "$d")" "$(j "$title")" "$(j "$(field "$t" scope)")" "$(j "$(field "$t" status)")" "$(j "$stage")" \
    "$(j "$(field "$t" complexity)")" "$(j "$waiting")" "$(jb "$needs")" "$(jb "$hold")" \
    "$(j "$(field "$t" repositories)")" "$(j "$(field "$t" merge_requests)")" "$(j "$(field "$t" created)")" "$agents_json" "$last")
  tasks_json=${tasks_json:+$tasks_json,$'\n  '}$tj
done < "$parts/order"

# Inbox: every unseen line, and the newest seen ones for context.
inbox_json="" unseen_md=""
if [ -f "$DATA/inbox.tsv" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    split_row "$line"
    if [ "$F5" = 0 ]; then s=false; unseen_md=$unseen_md"- $F1 · $(basename "$F2") · $F4 · $F3"$'\n'; else s=true; fi
    e=$(printf '{"time": %s, "task": %s, "file": %s, "from": %s, "seen": %s}' "$(j "$F1")" "$(j "$F2")" "$(j "$F3")" "$(j "$F4")" "$s")
    inbox_json=${inbox_json:+$inbox_json, }$e
  done < <(awk -F'\t' '$5!="1" { print; next } { s[++n] = $0 } END { for (i = (n > 20 ? n - 19 : 1); i <= n; i++) print s[i] }' "$DATA/inbox.tsv")
fi

no_health='{"verdict": "unknown", "readings": []}'
problems_json=$(paste -sd, "$parts/problems.json" 2>/dev/null)
{
  printf '{"generated": %s,\n "hold_all": %s,\n' "$(j "$(now)")" "$(jb "$hold_all")"
  printf ' "health": %s,\n' "${health:-$no_health}"
  printf ' "tasks": [%s],\n' "${tasks_json:+$'\n  '$tasks_json$'\n '}"
  printf ' "inbox": [%s],\n' "$inbox_json"
  printf ' "services": %s,\n' "${services:-[]}"
  printf ' "resources": %s,\n' "${resources:-[]}"
  printf ' "problems": [%s]}\n' "$problems_json"
} > "$js"

{
  echo "# Board ($(now))"
  echo
  if [ "$hold_all" = yes ]; then echo "Global merge hold: ON"; echo; fi
  echo "## Needs you"; echo
  if [ -s "$parts/needs" ]; then cat "$parts/needs"; else echo "Nothing."; fi
  echo; echo "## Running"
  if [ -s "$parts/running" ]; then cat "$parts/running"; else echo; echo "No open tasks."; fi
  echo; echo "## Finished, not yet seen"; echo
  if [ -n "$unseen_md" ]; then printf '%s' "$unseen_md"; else echo "Nothing."; fi
  echo; echo "## Services"; echo
  if [ -n "$services" ]; then
    printf '%s' "$services" | json_pairs | awk -F'\t' '
      function flush() { if (n != "") { print "- " n ": " (st == "" ? "unknown" : st) (pn == "" ? "" : " · " pn) (vb == "" ? "" : " · verbs: " vb) det } }
      $1 == "name" { flush(); n = $2; st = ""; pn = ""; vb = ""; det = "" }
      $1 == "state" { st = $2 } $1 == "panel" { pn = $2 } $1 == "detail" && $2 != "" { det = det "\n  - " $2 }
      $1 == "verb" { vb = vb (vb == "" ? "" : ", ") $2 }
      END { flush(); if (n == "") print "None registered." }'
  else echo "None registered."; fi
  echo; echo "## Machine"; echo
  if [ -n "$health" ]; then
    printf '%s' "$health" | json_pairs | awk -F'\t' '
      function flush() { if (n != "") print "- " n ": " v (l == "" ? "" : " (limit " l ")") " " s }
      $1 == "verdict" { print "Verdict: " $2 } $1 == "name" { flush(); n = $2; v = ""; l = ""; s = "" }
      $1 == "value" { v = $2 } $1 == "limit" { l = $2 } $1 == "state" { s = $2 } END { flush() }'
  else echo "Verdict: unknown (no health reading)"; fi
  # The counts are health.sh readings already; what only sweep.sh tells is how many no open task owns.
  if [ -n "$resources" ]; then
    printf '%s' "$resources" | json_pairs | awk -F'\t' '
      function flush() { if (k != "" && o > 0) print "- " k ": " o " not owned by an open task (sweep.sh --orphans lists them)" }
      $1 == "kind" { flush(); k = $2; o = 0 } $1 == "orphans" { o++ } END { flush() }'
  fi
  echo; echo "## Problems"; echo
  if [ -s "$parts/problems" ]; then cat "$parts/problems"; else echo "None."; fi
} > "$md"

mv "$js" "$DATA/board.json" && mv "$md" "$DATA/board.md"
