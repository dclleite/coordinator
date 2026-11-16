#!/bin/bash
# service.sh list | status [<name>|--all] [--json] | run <name> <verb> [--confirmed] | protected threads|paths
# A service is something long-running that is not a task; its binding is DATA/services/<name>.conf.
set -u
. "$(dirname "$0")/lib.sh"
SDIR=$DATA/services
TIMEOUT=${SERVICE_STATUS_TIMEOUT:-10}
case $TIMEOUT in ''|*[!0-9]*) die 2 "SERVICE_STATUS_TIMEOUT must be a whole number of seconds";; esac

usage() { die 2 "usage: service.sh list | status [<name>|--all] [--json] | run <name> <verb> [--confirmed] | protected threads|paths"; }

valid_name() { case $1 in ''|.*|*[!A-Za-z0-9._-]*) return 1;; esac; }

conf_of() {
  valid_name "$1" || die 2 "invalid service name: $1"
  [ -f "$SDIR/$1.conf" ] || die 2 "no such service: $1"
  printf '%s\n' "$SDIR/$1.conf"
}

# conf_get <file> <key>: prints the value of the first <key>= line; returns 1 when absent.
conf_get() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in "$2="*) printf '%s\n' "${line#*=}"; return 0;; esac
  done < "$1"
  return 1
}

names() {
  local f n
  for f in "$SDIR"/*.conf; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .conf); valid_name "$n" && printf '%s\n' "$n"
  done
}

verbs() { sed -n 's/^verb\.\([^=]*\)=.*/\1/p' "$1" | paste -sd, -; }

# Runs a configured command line in the services folder, with the service's name in the environment.
# The command is the binding's own text: the binding is private and written by the developer.
run_cmd() {
  (cd "$SDIR" && SERVICE_NAME=$1 SERVICE_DIR=$SDIR exec bash -c "$2")
}

# timed <seconds> <name> <command>: like run_cmd, its whole process group ended past the limit (exit 124).
timed() { (cd "$SDIR" && run_limited "$1" env SERVICE_NAME="$2" SERVICE_DIR="$SDIR" bash -c "$3"); }

# status_one <name> <json 0|1>: prints the service's state; the command's output is never written to disk.
status_one() {
  local f cmd out rc state detail="" panel line first=1 n=0
  f=$(conf_of "$1") || exit 2
  panel=$(conf_get "$f" panel) || panel=""
  if cmd=$(conf_get "$f" status) && [ -n "$cmd" ]; then
    out=$(timed "$TIMEOUT" "$1" "$cmd"); rc=$?
  else out=""; rc=-1; fi
  state=$(printf '%s\n' "$out" | head -1 | tr -d '[:space:]')
  case $state in ok|degraded|down) ;; *) state=unknown;; esac
  [ "$rc" -eq 0 ] || state=unknown
  if [ "$state" != unknown ]; then detail=$(printf '%s\n' "$out" | sed '1d' | grep -v '^[[:space:]]*$' | head -20)
  elif [ "$rc" -eq -1 ]; then detail="the binding has no status command"
  elif [ "$rc" -eq 124 ]; then detail="status timed out after ${TIMEOUT}s"
  elif [ "$rc" -ne 0 ]; then detail="status command failed (exit $rc)"
  else detail="status printed no state"; fi
  if [ "$2" = 1 ]; then
    printf '{"name":%s,"state":%s,"detail":[' "$(json_str "$1")" "$(json_str "$state")"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ "$first" = 1 ] || printf ','; first=0; json_str "$line"
    done <<< "$detail"
    printf '],"panel":%s,"verbs":[' "$(json_str "$panel")"
    first=1
    # Only verbs `run` would accept, and never their commands: a panel turns these into buttons.
    while IFS= read -r line; do
      case $line in verb.*=auto:?*|verb.*=confirm:?*) ;; *) continue;; esac
      line=${line#verb.}
      [ "$first" = 1 ] || printf ','; first=0
      printf '{"verb":%s,"class":%s}' "$(json_str "${line%%=*}")" "$(json_str "$(printf '%s' "${line#*=}" | cut -d: -f1)")"
    done < "$f"
    printf ']}'
  else
    printf '%s: %s\n' "$1" "$state"
    [ -z "$detail" ] || printf '%s\n' "$detail" | sed 's/^/  /'
    [ -z "$panel" ] || printf '  panel: %s\n' "$panel"
  fi
}

cmd_status() {
  local target=--all json=0 a n first=1
  for a in "$@"; do case $a in --json) json=1;; --all) target=--all;; -*) usage;; *) target=$a;; esac; done
  if [ "$target" != --all ]; then status_one "$target" "$json"; [ "$json" = 0 ] || echo; return; fi
  [ "$json" = 0 ] || printf '['
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ "$json" = 1 ]; then [ "$first" = 1 ] || printf ','; fi
    first=0; status_one "$n" "$json"
  done <<< "$(names)"
  [ "$json" = 0 ] || echo ']'
}

cmd_list() {
  local n f scope
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f=$SDIR/$n.conf; scope=$(conf_get "$f" scope) || scope=-
    printf '%s scope=%s verbs=%s\n' "$n" "${scope:--}" "$(verbs "$f")"
  done <<< "$(names)"
}

log_run() { printf '%s\t%s\t%s\n' "$(now)" "$2" "$3" >> "$SDIR/$1.log"; }

cmd_run() {
  local name=${1:-} verb=${2:-} confirmed=0 f spec class cmd rc
  [ -n "$name" ] && [ -n "$verb" ] || usage
  case ${3:-} in '') ;; --confirmed) confirmed=1;; *) usage;; esac
  [ $# -le 3 ] || usage
  f=$(conf_of "$name") || exit 2
  spec=$(conf_get "$f" "verb.$verb") || die 2 "service $name has no verb $verb (verbs: $(verbs "$f"))"
  class=${spec%%:*}; cmd=${spec#*:}
  [ "$spec" != "$class" ] && [ -n "$cmd" ] || die 2 "verb.$verb of $name must be <class>:<command>"
  case $class in auto|confirm) ;; *) die 2 "verb.$verb of $name has class $class; use auto or confirm";; esac
  if [ "$class" = confirm ] && [ "$confirmed" = 0 ]; then
    log_run "$name" "$verb" refused
    die 1 "refused: $name $verb needs the developer's word; run again with --confirmed once given"
  fi
  run_cmd "$name" "$cmd"; rc=$?
  log_run "$name" "$verb" "$rc"
  return "$rc"
}

cmd_protected() {
  local key n f v item
  case ${1:-} in threads) key=threads;; paths) key=protect;; *) usage;; esac
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f=$SDIR/$n.conf; v=$(conf_get "$f" "$key") || continue
    printf '%s\n' "$v" | tr ',' '\n' | while IFS= read -r item; do
      item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -n "$item" ] || continue
      case $item in "~/"*) item=$HOME/${item#"~/"};; esac
      printf '%s\n' "$item"
    done
  done <<< "$(names)" | awk '!seen[$0]++'
}

[ $# -ge 1 ] || usage
sub=$1; shift
case $sub in
  list) [ $# -eq 0 ] || usage; cmd_list;;
  status) cmd_status "$@";;
  run) cmd_run "$@";;
  protected) [ $# -eq 1 ] || usage; cmd_protected "$1";;
  *) usage;;
esac
