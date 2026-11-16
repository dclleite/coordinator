#!/bin/bash
# health.sh [--json]  ->  three readings, one line per resource row and a verdict;
# exit 0 when disk and memory are known and every reading is within limits (--json exits 0 whenever it printed)
set -u
. "$(dirname "$0")/lib.sh"
. "$ROOT/config/health.conf"
json=0; [ "${1:-}" = --json ] && json=1

for t in MIN_FREE_DISK_GB MIN_FREE_MEM_PCT MAX_RUNNING_CONTAINERS; do
  case "${!t:-}" in ''|*[!0-9]*) die 2 "config/health.conf: $t must be a whole number" ;; esac
done
CTIMEOUT=${CONTAINER_TIMEOUT_SEC:-3}; case "$CTIMEOUT" in ''|*[!0-9]*) CTIMEOUT=3 ;; esac

number() { case "$1" in ''|*[!0-9]*) echo unknown ;; *) echo "$1" ;; esac; }

# An engine that does not answer reads unknown within its own short limit, and stops nothing.
containers() {
  command -v docker >/dev/null 2>&1 || { echo 0; return; }
  local out
  out=$(run_limited "$CTIMEOUT" docker ps -q) || { echo unknown; return; }
  printf '%s\n' "$out" | grep -c .
}
memory() {
  local f=${HEALTH_MEMINFO:-}
  if [ -z "$f" ] && command -v memory_pressure >/dev/null 2>&1; then
    memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'; return
  fi
  awk '$1=="MemTotal:" {t=$2} $1=="MemAvailable:" {a=$2} END {if (t>0 && a!="") print int(a*100/t)}' \
    "${f:-/proc/meminfo}" 2>/dev/null
}

disk=${HEALTH_DISK_FREE_GB:-$(df -Pk "${HEALTH_DISK_PATH:-$HOME}" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')}
mem=${HEALTH_MEM_FREE_PCT:-$(memory)}
cont=${HEALTH_CONTAINERS:-$(containers)}
disk=$(number "$disk"); mem=$(number "$mem"); cont=$(number "$cont")

reasons=""; lines=""; readings=""
# report <label> <value> <limit-name> <limit> <min|max> <reason-name> <word when out of range> [unknown-ok]
report() {
  local state=ok
  if [ "$2" = unknown ]; then state=unknown; [ -n "${8:-}" ] || reasons=${reasons:+$reasons, }"$6 unknown"
  elif { [ "$5" = min ] && [ "$2" -lt "$4" ]; } || { [ "$5" = max ] && [ "$2" -gt "$4" ]; }; then
    state=$7; reasons=${reasons:+$reasons, }$6
  fi
  add "$1" "$2" "$3" "$4" "$state"
}
add() { # <name> <value> <limit-name> <limit> <state>
  lines=${lines:+$lines$'\n'}"$1=$2 $3=$4 $5"
  readings=${readings:+$readings,}$(printf '{"name":%s,"value":%s,"limit":%s,"state":%s}' \
    "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$4")" "$(json_str "$5")")
}
report disk_free_gb "$disk" min "$MIN_FREE_DISK_GB" min disk LOW
report mem_free_pct "$mem" min "$MIN_FREE_MEM_PCT" min memory LOW
report containers "$cont" max "$MAX_RUNNING_CONTAINERS" max containers HIGH unknown-ok

# Resource rows: over the limit is unhealthy; unknown means the command cannot run here and is not.
while IFS= read -r r; do
  [ -n "$r" ] || continue
  split_row "$r"
  add "resource.$F1" "$F2" max "$F3" "$F4"
  [ "$F4" = HIGH ] && reasons=${reasons:+$reasons, }$F1
done <<< "$("$SCRIPTS/sweep.sh" --readings 2>/dev/null)"

if [ -z "$reasons" ]; then verdict=healthy; else verdict="unhealthy: $reasons"; fi
if [ $json -eq 1 ]; then
  printf '{"verdict":%s,"readings":[%s]}\n' "$(json_str "$verdict")" "$readings"; exit 0
fi
printf '%s\n%s\n' "$lines" "$verdict"
[ -z "$reasons" ] || { echo "$verdict" >&2; exit 1; }
