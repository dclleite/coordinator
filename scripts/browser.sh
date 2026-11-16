#!/bin/bash
# browser.sh run <task-dir> <agent> [--keep] [--] <tool args...>   one named browser per task and agent
# browser.sh stop <task-dir> <agent>          stops that agent's browser and closes its record
# browser.sh name <task-dir> <agent>
# browser.sh list | count | age <name> | stop-name <name>
# browser.sh profiles | profile-rm <name> | tmp-count | tmp-clean <days> [--dry-run]
# Reading never starts the tool's daemon: list and count read the process table, not the tool.
set -u
. "$(dirname "$0")/lib.sh"
. "$ROOT/config/health.conf"
export BROWSER_HOME
TOOL=${BROWSER_TOOL:-dev-browser}

need_tool() { command -v "$TOOL" >/dev/null 2>&1 || die 2 "browser tool not installed: $TOOL"; }
clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-'; }
name_for() { task_dir "$1"; echo "$(clean "$(basename "$1")")-$(clean "$2")"; }
valid_name() { case "$1" in ''|.|..|*/*|*$'\n'*) die 2 "not a browser name: $1" ;; esac; }

# Running browsers: each one is a Chromium whose profile is <home>/browsers/<name>/chromium-profile.
list() {
  ps -A -o args= 2>/dev/null | awk '{
      p = ENVIRON["BROWSER_HOME"] "/browsers/"; i = index($0, p)
      if (!i) next
      rest = substr($0, i + length(p)); j = index(rest, "/chromium-profile")
      if (j > 1) print substr(rest, 1, j - 1) }' | sort -u
}
age() { # seconds since the oldest process of that browser started
  ps -A -o etime=,args= 2>/dev/null | N=$1 awk '
    index($0, ENVIRON["BROWSER_HOME"] "/browsers/" ENVIRON["N"] "/chromium-profile") {
      t = $1; d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]
      s += d * 86400; if (s > m) m = s }
    END { print m + 0 }'
}
# The tool's CLI can only stop every browser at once; its daemon socket also accepts a per-browser stop.
stop_name() {
  valid_name "$1"
  list | grep -qxF -- "$1" || { echo "not running: $1"; return 0; }
  need_tool
  [ -S "$BROWSER_HOME/daemon.sock" ] || [ -e "$BROWSER_HOME/daemon.sock" ] || die 1 "daemon socket missing; $1 left running"
  command -v node >/dev/null 2>&1 || die 1 "node not found; $1 left running"
  B=$1 node -e '
    const s = require("net").connect(process.env.BROWSER_HOME + "/daemon.sock");
    const id = "coord-" + process.pid; let buf = "";
    const done = (c, m) => { if (m) console.error(m); s.destroy(); process.exit(c); };
    setTimeout(() => done(1, "no answer from the browser daemon"), 15000);
    s.on("error", e => done(1, e.message));
    s.on("connect", () => s.write(JSON.stringify({ id, type: "browser-stop", browser: process.env.B }) + "\n"));
    s.on("data", d => { buf += d; let i;
      while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1);
        let m; try { m = JSON.parse(l); } catch (e) { continue; }
        if (m.type === "error") done(1, m.message || "daemon error");
        if (m.type === "complete") done(m.success ? 0 : 1); } });' || die 1 "could not stop $1"
  echo "stopped: $1"
}

case "${1:-}" in
list) list ;;
count) list | grep -c . || true ;;
age) [ $# -eq 2 ] || die 2 "usage: browser.sh age <name>"; valid_name "$2"; age "$2" ;;
stop-name) [ $# -eq 2 ] || die 2 "usage: browser.sh stop-name <name>"; stop_name "$2" ;;
name) [ $# -eq 3 ] || die 2 "usage: browser.sh name <task-dir> <agent>"; name_for "$2" "$3" ;;
profiles) [ -d "$BROWSER_HOME/browsers" ] && ls -1 "$BROWSER_HOME/browsers" ; exit 0 ;;
profile-rm)
  [ $# -eq 2 ] || die 2 "usage: browser.sh profile-rm <name>"; valid_name "$2"
  list | grep -qxF -- "$2" && die 1 "running, not removed: $2"
  [ -d "$BROWSER_HOME/browsers/$2" ] || { echo "no profile: $2"; exit 0; }
  rm -rf "$BROWSER_HOME/browsers/$2" && echo "removed profile: $2" ;;
tmp-count) [ -d "$BROWSER_HOME/tmp" ] || { echo 0; exit 0; }; find "$BROWSER_HOME/tmp" -type f | grep -c . || true ;;
tmp-clean)
  [ $# -ge 2 ] || die 2 "usage: browser.sh tmp-clean <days> [--dry-run]"
  case "$2" in ''|*[!0-9]*) die 2 "days must be a whole number" ;; esac
  [ -d "$BROWSER_HOME/tmp" ] || { echo "tmp_old=0"; exit 0; }
  n=$(find "$BROWSER_HOME/tmp" -type f -mtime +"$2" | grep -c .)
  if [ "${3:-}" = --dry-run ]; then echo "tmp_old=$n would delete"
  else find "$BROWSER_HOME/tmp" -type f -mtime +"$2" -exec rm -f {} +; echo "tmp_old=$n deleted"; fi ;;
stop)
  [ $# -eq 3 ] || die 2 "usage: browser.sh stop <task-dir> <agent>"
  n=$(name_for "$2" "$3"); stop_name "$n" || exit 1
  "$SCRIPTS/resource-done.sh" "$2" browsers "$n" >/dev/null 2>&1; exit 0 ;;
run)
  [ $# -ge 3 ] || die 2 "usage: browser.sh run <task-dir> <agent> [--keep] [--] <tool args...>"
  dir=$2; n=$(name_for "$2" "$3") || exit 2; shift 3; keep=0
  [ "${1:-}" = --keep ] && { keep=1; shift; }
  [ "${1:-}" = -- ] && shift
  for a in "$@"; do case "$a" in --browser|--browser=*) die 2 "the wrapper names the browser; drop --browser" ;; esac; done
  need_tool
  limit=$("$SCRIPTS/sweep.sh" --run browsers limit 2>/dev/null); running=$(list)
  if ! grep -qxF -- "$n" <<< "$running"; then
    c=$(printf '%s' "$running" | grep -c .)
    case "$limit" in ''|-|*[!0-9]*) ;; *)
      [ "$c" -lt "$limit" ] || die 1 "browser limit reached ($c of $limit running); stop one before opening $n" ;;
    esac
  fi
  "$SCRIPTS/resource-add.sh" "$dir" browsers "$n" >/dev/null || exit 1
  if [ $keep -eq 0 ]; then
    trap 'stop_name "$n" >/dev/null 2>&1 && "$SCRIPTS/resource-done.sh" "$dir" browsers "$n" >/dev/null 2>&1' EXIT
    trap 'exit 130' INT TERM
  fi
  "$TOOL" --browser "$n" "$@" ;;
*) die 2 "usage: browser.sh run|stop|name|list|count|age|stop-name|profiles|profile-rm|tmp-count|tmp-clean" ;;
esac
