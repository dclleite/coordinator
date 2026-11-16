# Sourced by every script. COORD_ROOT overrides the root (tests use it).
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ -n "${COORD_ROOT:-}" ]; then ROOT=$COORD_ROOT; else ROOT=$(cd "$SCRIPTS/.." && pwd -P); fi
# Everything sensitive (task records, board, local routing) lives under DATA, which git ignores.
DATA=${COORD_DATA:-$ROOT/.private}
# A git worktree of this repository has no data folder of its own: it shares the main checkout's.
if [ -z "${COORD_DATA:-}" ] && [ ! -d "$DATA" ]; then
  _common=$(cd "$ROOT" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || _common=""
  case "$_common" in /*/.git) [ -d "${_common%/.git}/.private" ] && DATA=${_common%/.git}/.private ;; esac
fi

die() { local code=$1; shift; echo "$*" >&2; exit "$code"; }

now() {
  if [ -n "${COORD_NOW:-}" ]; then echo "$COORD_NOW"
  else date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'; fi
}

# Prints the value of one frontmatter field of a task.md.
field() { awk -v k="$2" 'NR>1 && /^---$/ {exit} index($0, k": ")==1 {print substr($0, length(k)+3)} $0==k":" {print ""}' "$1"; }

# tool_path <name>: the command's path, from PATH or else from a place installers use outside it.
tool_path() {
  local c d
  c=$(command -v "$1" 2>/dev/null) && [ -x "$c" ] && { echo "$c"; return 0; }
  for d in "${HOME:-/nonexistent}/.t3/bin" "${HOME:-/nonexistent}/.local/bin" "${HOME:-/nonexistent}/.docker/bin"; do
    [ -f "$d/$1" ] && [ -x "$d/$1" ] && { echo "$d/$1"; return 0; }
  done
  return 1
}

# path_hint <path>: one line saying a command was found outside PATH, with the line that puts it on PATH.
path_hint() {
  local d=${1%/*}
  case "$d" in "${HOME:-/nonexistent}"/*) d='$HOME'${d#"$HOME"} ;; esac
  printf '%s: found at %s, not on PATH; add to your shell profile: export PATH="%s:$PATH"\n' "${1##*/}" "$1" "$d"
}

task_dir() { [ -f "$1/task.md" ] || die 2 "not a task folder: $1"; }

# Physical path of an existing folder; empty when it does not exist.
# bash's pwd -P keeps the macOS data-volume prefix, so one folder could have two spellings.
physical() {
  local p
  p=$(cd -P "$1" 2>/dev/null && pwd -P) || return 0
  case "$p" in /System/Volumes/Data/*) [ "${p#/System/Volumes/Data}" -ef "$p" ] && p=${p#/System/Volumes/Data} ;; esac
  echo "$p"
}

# split_row <line>: sets F1..F11 from a tab-separated line, keeping empty columns in place.
# (read with a tab IFS would collapse them and shift every later column.)
split_row() {
  local IFS=$'\x1f'
  read -r F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 <<< "${1//$'\t'/$'\x1f'}"
}

# agent_row <agents.tsv line>: split_row, with the defaults of a row written before parent and state.
agent_row() { split_row "$1"; F10=${F10:--} F11=${F11:-unknown}; }

# worktree_removable <repo> <worktree> <mr_sha>: prints the reason and returns 1 when it must be kept.
worktree_removable() {
  local repo=$1 wt=$2 sha=$3 real head
  real=$(physical "$wt")
  if [ -n "$real" ] && [ "$real" = "$(physical "$repo")" ]; then echo "the main checkout"; return 1; fi
  if [ -z "$real" ] || ! git -C "$repo" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $real"; then
    echo "not a registered worktree"; return 1; fi
  if [ -n "$(git -C "$real" status --porcelain 2>/dev/null)" ]; then echo "uncommitted changes"; return 1; fi
  head=$(git -C "$real" rev-parse HEAD 2>/dev/null)
  if [ "$head" != "$sha" ] && [ -z "$(git -C "$real" branch -r --contains HEAD 2>/dev/null)" ]; then
    echo "work not on the remote"; return 1; fi
  return 0
}

# json_str <text>: prints <text> as one JSON string literal, quotes included.
json_str() {
  printf '%s' "$1" | LC_ALL=C awk 'BEGIN { ORS=""; print "\"" }
    { if (NR > 1) print "\\n"
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
      gsub(/[\001-\010\013\014\016-\037]/, ""); print }
    END { print "\"" }'
}

# sha256 < file: the hex digest, from whichever of shasum and sha256sum exists; both print it first.
sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else echo "no sha256 tool: install shasum or sha256sum" >&2; return 2; fi
}

# lock_take <lock-folder> / lock_drop <lock-folder>: one writer at a time on a record.
# The wait is bounded (LOCK_WAIT_SEC). A lock whose owner process is gone (by id and start time) is taken over;
# a live owner keeps it however long it holds. lock_drop removes only a lock this process holds.
_LOCK_ME="$$.$RANDOM$RANDOM"
_lock_owner() { local t=""; [ -f "$1/owner" ] && read -r t _ < "$1/owner" 2>/dev/null; echo "$t"; }
_lock_stale() {
  local t="" when="" start="" pid now
  [ -f "$1/owner" ] && read -r t when start < "$1/owner" 2>/dev/null
  pid=${t%%.*}
  case "$pid" in
    # No owner written yet: only a writer that died between mkdir and the write leaves it, so wait a minute.
    ''|*[!0-9]*) [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; return ;;
  esac
  now=$(proc_start "$pid")
  [ -z "$now" ] && return 0
  [ -n "$start" ] && [ "$now" != "$start" ]
}
lock_take() {
  local l=$1 i=0 max seen
  max=$(( ${LOCK_WAIT_SEC:-30} * 10 ))
  until mkdir "$l" 2>/dev/null; do
    if [ -d "$l" ] && _lock_stale "$l"; then
      # Read the owner again just before removing, so a lock another waiter has just taken over is kept.
      seen=$(_lock_owner "$l")
      if _lock_stale "$l" && [ "$(_lock_owner "$l")" = "$seen" ]; then rm -rf "$l"; continue; fi
    fi
    i=$((i + 1)); [ "$i" -lt "$max" ] || die 1 "busy: $l is held by another writer"
    sleep 0.1
  done
  printf '%s %s %s\n' "$_LOCK_ME" "$(date +%s)" "$(proc_start $$)" > "$l/owner"
}
lock_drop() { [ -d "$1" ] && [ "$(_lock_owner "$1")" = "$_LOCK_ME" ] && rm -rf "$1"; return 0; }

# proc_start <pid>: the start time of a process as ps prints it, on one line; empty once it is gone.
proc_start() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }

# agent_run_ours <pid>: true only while process group <pid> is still an agent dispatch.sh launch started,
# by the start time it saved in runs/*.start. Ids 0 and 1 would signal the caller's group or every process.
agent_run_ours() {
  local n=$1 rec now
  case "$n" in ''|*[!0-9]*|0*|1) return 1 ;; esac
  kill -0 -- "-$n" 2>/dev/null || return 1
  rec=$(cat "$DATA"/tasks/*/*/runs/*.start 2>/dev/null | awk -F'\t' -v p="$n" '$1==p && $2!="" {print $2}')
  [ -n "$rec" ] || return 1
  now=$(proc_start "$n")
  # The leader is gone and its group lives on: no new process can get an id still used as a group id.
  [ -n "$now" ] || return 0
  grep -qxF -- "$now" <<< "$rec"
}

# run_limited <seconds> <command> [<args>...]: the command's stdout, with stdin and stderr closed off;
# exit 124 at the limit. The command runs in a process group of its own, ended whole when it returns,
# and by a watchdog in another group at the limit or as soon as this script is gone.
run_limited() {
  local t=$1 pid w rc start=$SECONDS; shift
  set -m
  "$@" </dev/null 2>/dev/null &
  pid=$!
  _limit_watch "$t" "$pid" "$$" </dev/null >/dev/null 2>&1 &
  w=$!
  set +m
  wait "$pid" 2>/dev/null; rc=$?
  _group_end "$pid"
  kill -TERM -- "-$w" 2>/dev/null; wait "$w" 2>/dev/null
  if [ "$rc" -gt 128 ] && [ $((SECONDS - start)) -ge "$t" ]; then return 124; fi
  return "$rc"
}
_group_end() { kill -TERM -- "-$1" 2>/dev/null && { sleep 0.2; kill -KILL -- "-$1" 2>/dev/null; }; return 0; }
_limit_watch() { # <seconds> <group> <caller>
  local i=0 max=$(( $1 * 10 ))
  while [ "$i" -lt "$max" ] && kill -0 "$3" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  _group_end "$2"
}
