#!/bin/bash
# panel.sh start | stop | status | url   ->  the only way the local panel server is started and stopped
#   start and url print the address with its key (the page opens only from it); status prints it without the key
# panel.sh reap [--dry-run]   ->  stops a panel whose last accepted request is older than twice PANEL_IDLE_MIN
set -u
. "$(dirname "$0")/lib.sh"
usage() { die 2 "usage: panel.sh start | stop | status | url | reap [--dry-run]"; }
[ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$1" = reap ] && [ "$2" = --dry-run ]; } || usage
P=$DATA/panel
CONF=$ROOT/config/panel.conf

conf() { # <key> <default>
  local v
  v=$(sed -n "s/^$1=\([0-9][0-9.]*\)[[:space:]]*\$/\1/p" "$CONF" 2>/dev/null | tail -1)
  printf '%s\n' "${v:-$2}"
}

# alive: true when the pid file names a running panel server (a reused pid is not one).
alive() {
  local pid
  pid=$(cat "$P/pid" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'panel-server\.py'
}
address() { echo "http://127.0.0.1:$(cat "$P/port" 2>/dev/null)/"; }
url() { echo "$(address)?key=$(cat "$P/token" 2>/dev/null)"; }

# Start and stop share one lock: a stop still waiting on the old server must not remove a new start's files.
lock() {
  local i=0
  (umask 077; mkdir -p "$P") || die 1 "cannot write in $P"
  until mkdir "$P/.start.lock" 2>/dev/null; do
    i=$((i + 1)); [ $i -lt 600 ] || { rm -rf "$P/.start.lock"; i=0; }; sleep 0.1
  done
  trap 'rmdir "$P/.start.lock" 2>/dev/null' EXIT
}

stop() {
  local pid i=0
  if alive; then
    pid=$(cat "$P/pid")
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$P/pid" "$P/port" "$P/token" "$P/last" "$P/pid.tmp" "$P/port.tmp" "$P/last.tmp"
}

case "$1" in
status) if alive; then echo "running $(address)"; else echo stopped; fi ;;
reap)
  alive || exit 0
  idle=$(conf PANEL_IDLE_MIN 30)
  last=$(cat "$P/last" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # Whole seconds; awk takes the decimal part of PANEL_IDLE_MIN.
  limit=$(awk -v m="$idle" 'BEGIN { printf "%d", m * 120 }')
  quiet=$(( $(date +%s) - last ))
  [ "$quiet" -gt "$limit" ] || exit 0
  why="no accepted request for $((quiet / 60)) min (idle limit $idle min)"
  if [ "${2:-}" = --dry-run ]; then echo "would stop panel: $why"; exit 0; fi
  lock; stop; echo "stopped panel: $why" ;;
url) alive || die 1 "stopped"; url ;;
stop) [ -d "$P" ] && lock; stop; echo stopped ;;
start)
  command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 7))' 2>/dev/null \
    || die 2 "the panel needs Python 3.7 or later; the text board (status.sh) works without it"
  from=$(conf PANEL_PORT_FROM 8765); idle=$(conf PANEL_IDLE_MIN 30); refresh=$(conf PANEL_REFRESH_SEC 10)
  case "$from$refresh" in *[!0-9]*) die 2 "config/panel.conf: PANEL_PORT_FROM and PANEL_REFRESH_SEC must be whole numbers" ;; esac
  case "$idle" in *.*.*|.*|*.) die 2 "config/panel.conf: PANEL_IDLE_MIN must be a number" ;; esac
  [ "$from" -ge 1024 ] && [ "$from" -le 65000 ] || die 2 "config/panel.conf: PANEL_PORT_FROM must be between 1024 and 65000"
  lock; chmod 700 "$P"
  if alive; then url; exit 0; fi
  stop >/dev/null
  (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$P/token") || die 1 "cannot write the token"
  COORD_DATA=$DATA nohup python3 "$SCRIPTS/panel-server.py" --data "$DATA" --scripts "$SCRIPTS" \
    --page "$SCRIPTS/../panel/index.html" --actions "$ROOT/config/panel-actions.tsv" --token-file "$P/token" \
    --port-from "$from" --idle-min "$idle" --refresh-sec "$refresh" </dev/null >/dev/null 2>&1 &
  i=0; while [ $i -lt 300 ]; do
    [ -s "$P/port" ] && alive && { url; exit 0; }
    kill -0 $! 2>/dev/null || break
    sleep 0.1; i=$((i + 1))
  done
  kill $! 2>/dev/null; stop >/dev/null
  die 1 "the panel server did not start (no free port from $from?)" ;;
*) usage ;;
esac
