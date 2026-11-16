. "$(dirname "$0")/lib.sh"
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "panel tests skipped: python3 or curl is missing"; exit 0
fi
mktask; S=$ROOT/scripts; P=$COORD_DATA/panel; W=$_TMPROOT/w; mkdir -p "$W"
export COORD_TOOLS=$_TMPROOT/no-tools
# reap.sh and sweep.sh read only the fixture: the panel row, and a browser home with nothing in it.
export BROWSER_HOME=$_TMPROOT/bh; mkdir -p "$BROWSER_HOME/tmp"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' panel \
  "\"\$SCRIPTS\"/panel.sh status | awk '\$1==\"running\" {n++} END {print n+0}'" 1 \
  "\"\$SCRIPTS\"/panel.sh status | awk '\$1==\"running\" {print \"panel\"}'" "\"\$SCRIPTS\"/panel.sh stop" auto \
  > "$COORD_ROOT/config/resources.tsv"
# Anything a test leaves running dies with the fixture.
trap '"$S"/panel.sh stop >/dev/null 2>&1; _finish' EXIT

# A port the kernel hands out can lie above 65000, which panel.conf refuses; pick from a fixed range instead.
free_port() { python3 -c 'import random, socket
while True:
    p = random.randint(20000, 60000); s = socket.socket()
    try: s.bind(("127.0.0.1", p)); print(p); break
    except OSError: pass
    finally: s.close()'; }
# start_ok: starts the panel and sets URL, PORT and pid; any failure to start is a failed check, never a pass.
start_ok() { url=$($S/panel.sh start); local rc=$?; PORT=$(cat "$P/port" 2>/dev/null); pid=$(cat "$P/pid" 2>/dev/null)
  local got=port; case "$PORT" in ''|*[!0-9]*) got=none ;; esac
  eq "${1:-start} succeeded" "0 port" "$rc $got"; }
setconf() { # <key> <value>
  grep -v "^$1=" "$COORD_ROOT/config/panel.conf" > "$W/conf"; echo "$1=$2" >> "$W/conf"
  mv "$W/conf" "$COORD_ROOT/config/panel.conf"
}
# req <method> <path> [curl args...]: prints the status code; body in $W/body, headers in $W/hdr.
req() {
  local m=$1 path=$2; shift 2
  curl -s -X "$m" -o "$W/body" -D "$W/hdr" -w '%{http_code}' "$@" "http://127.0.0.1:$PORT$path"
}
tok() { cat "$P/token"; }
run() { # <json> [extra curl args]: POST /api/run with the token
  local j=$1; shift
  req POST /api/run -H "X-Panel-Token: $(tok)" -H 'Content-Type: application/json' --data-binary "$j" "$@"
}
gone() { local i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; ! kill -0 "$1" 2>/dev/null; }

setconf PANEL_PORT_FROM "$(free_port)"
setconf PANEL_REFRESH_SEC 1
A=$($S/task-new.sh company ACME-1 alpha "Alpha secret title")
for n in 1 2 3 4 5 6 7 8 9 10; do $S/ledger.sh "$A" note "line $n" >/dev/null; done
Bt=$($S/task-new.sh company ACME-2 beta "Beta closed"); $S/task-set.sh "$Bt" status closed
mkdir -p "$COORD_DATA/services"
cat > "$COORD_DATA/services/acme.conf" <<'CONF'
status=echo ok
verb.ping=auto:echo pong
verb.restart=confirm:touch restarted.txt
panel=http://127.0.0.1:9/
CONF

# Python too old or missing: exit 2, nothing started.
mkdir -p "$W/bin"; printf '#!/bin/sh\nexit 1\n' > "$W/bin/python3"; chmod +x "$W/bin/python3"
fails 2 "no usable python is exit 2" env PATH="$W/bin:$PATH" "$S/panel.sh" start
eq "status never starts anything" stopped "$($S/panel.sh status)"
ok "status left no pid file" test ! -e "$P/pid"
fails 2 "unknown verb" "$S/panel.sh" open

start_ok
eq "start prints the URL with its key" "http://127.0.0.1:$PORT/?key=$(tok)" "$url"
eq "status names the address without the key" "running http://127.0.0.1:$PORT/" "$($S/panel.sh status)"
eq "url" "$url" "$($S/panel.sh url)"
eq "token file is private" 600 "$(stat -c %a "$P/token" 2>/dev/null || stat -f %Lp "$P/token")"
eq "second start prints the same URL" "$url" "$($S/panel.sh start)"
eq "second start started nothing" "$pid" "$(cat "$P/pid")"
eq "one server process" 1 "$(ps -eo command | grep -c "[p]anel-server.py --data $COORD_DATA ")"
if command -v lsof >/dev/null 2>&1; then
  eq "listens on 127.0.0.1 only" "127.0.0.1:$PORT" "$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN -Fn | sed -n 's/^n//p' | sort -u | paste -sd' ' -)"
elif command -v ss >/dev/null 2>&1; then
  eq "listens on 127.0.0.1 only" "127.0.0.1:$PORT" "$(ss -ltnH "sport = :$PORT" | awk '{print $4}' | sort -u | paste -sd' ' -)"
else echo "listen address not checked: neither lsof nor ss"; fi

# The page: served only for the address with the key, carries the token, holds no data.
eq "page without the key refused" 403 "$(req GET /)"
ok "the refusal names the command that prints the address" grep -qF 'scripts/panel.sh url' "$W/body"
fails 1 "the refusal does not carry the token" grep -qF "$(tok)" "$W/body"
eq "page with a wrong key refused" 403 "$(req GET '/?key=nope')"
eq "index.html without the key refused" 403 "$(req GET /index.html)"
eq "wrong Host refused even with the key" 403 "$(req GET "/?key=$(tok)" -H "Host: rebound.example.invalid:$PORT")"
eq "page served" 200 "$(req GET "/?key=$(tok)")"
ok "page is HTML" grep -qi '^content-type: text/html' "$W/hdr"
ok "page carries this start's token" grep -qF "$(tok)" "$W/body"
fails 1 "page holds no task data" grep -q 'Alpha secret title' "$W/body"
ok "page cannot be framed" grep -qi "frame-ancestors 'none'" "$W/hdr"
H=$ROOT/panel/index.html
fails 1 "page never parses data as markup" grep -qE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write' "$H"
fails 1 "page makes no external request" grep -qiE '(src|href)="?https?:|@import|:[[:space:]]*url\(' "$H"
ok "page asks only while its tab is visible" grep -q 'document.hidden' "$H"
ok "page removes the key from the address bar" grep -q 'history.replaceState' "$H"
fails 1 "page uses no browser dialog" grep -qE '(alert|confirm|prompt)\(' "$H"
fails 1 "page names no network address at all" grep -qiE 'https?://|//[a-z0-9.-]+\.[a-z]{2,}/' "$H"
ok "page asks for no favicon from the server" grep -qF '<link rel="icon" href="data:,">' "$H"
fails 1 "served page has every placeholder filled" grep -qF '__PANEL_' "$W/body"
ok "an action button is disabled while another runs" grep -qF 'b.disabled = !!ui.running' "$H"
ok "a confirm button only opens the question" grep -qF 'if (confirm) { ui.asking = key' "$H"
eq "only the question's own button sends confirmed" 1 "$(grep -c 'press(a, target, true' "$H")"
ok "Escape closes the question" grep -qF '"Escape"' "$H"

# Protection.
eq "board without token refused" 403 "$(req GET /api/board)"
eq "board with a wrong token refused" 403 "$(req GET /api/board -H 'X-Panel-Token: nope')"
eq "wrong Host refused on the API" 403 "$(req GET /api/board -H "X-Panel-Token: $(tok)" -H "Host: rebound.example.invalid:$PORT")"
eq "localhost Host accepted" 200 "$(req GET /api/board -H "X-Panel-Token: $(tok)" -H "Host: localhost:$PORT")"
eq "POST from another site's Origin refused" 403 "$(run '{"id":"hold-on","task":"company/ACME-1-alpha"}' -H 'Origin: http://evil.example.invalid')"
eq "POST with Sec-Fetch-Site cross-site refused" 403 "$(run '{"id":"hold-on","task":"company/ACME-1-alpha"}' -H 'Sec-Fetch-Site: cross-site')"
eq "POST with Sec-Fetch-Site same-site refused" 403 "$(run '{"id":"hold-on","task":"company/ACME-1-alpha"}' -H 'Sec-Fetch-Site: same-site')"
eq "own Origin accepted" 200 "$(run '{"id":"refresh"}' -H "Origin: http://127.0.0.1:$PORT")"
eq "POST that is not JSON refused" 415 "$(req POST /api/run -H "X-Panel-Token: $(tok)" -H 'Content-Type: text/plain' --data-binary '{"id":"refresh"}')"
eq "form POST refused" 415 "$(req POST /api/run -H "X-Panel-Token: $(tok)" --data 'id=refresh')"
eq "JSON type with a broken body refused" 400 "$(run 'id=refresh')"
eq "OPTIONS refused" 405 "$(req OPTIONS /api/run -H "Origin: http://evil.example.invalid" -H 'Access-Control-Request-Method: POST')"
ok "no cross-origin header on a refusal" sh -c "! grep -qi '^access-control-' '$W/hdr'"
fails 1 "hold untouched by the refused presses" grep -q $'\thold\t' "$A/ledger.md"

# Board and actions.
eq "board answers" 200 "$(req GET /api/board -H "X-Panel-Token: $(tok)")"
ok "board is board.json" grep -q '"title": "Alpha secret title"' "$W/body"
bj() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"j": json.load(open(sys.argv[2]))}))' "$1" "$W/body"; }
eq "board says it was rebuilt" True "$(bj 'j["panel"]["rebuilt"]')"
eq "board carries the ledger tail of open tasks" "company/ACME-1-alpha" "$(bj '" ".join(sorted(j["panel"]["ledgers"]))')"
eq "board carries closed tasks" "company/ACME-2-beta Beta closed" "$(bj '" ".join(c["task"]+" "+c["title"] for c in j["panel"]["closed"])')"
ok "no cross-origin header on an answer" sh -c "! grep -qi '^access-control-' '$W/hdr'"
eq "actions answer" 200 "$(req GET /api/actions -H "X-Panel-Token: $(tok)")"
cp "$W/body" "$W/actions"
pick() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"j": json.load(open(sys.argv[2]))}))' "$1" "$W/actions"; }
eq "global buttons" "refresh inbox-seen hold-all-on reap-preview reap panel-stop" "$(pick '" ".join(a["id"] for a in j["global"])')"
eq "task buttons apply now" "company/ACME-1-alpha: hold-on sweep-task" "$(pick '"; ".join(t["task"]+": "+" ".join(a["id"] for a in t["actions"]) for t in j["tasks"])')"
eq "service verbs take the binding's class" "ping:auto restart:confirm" "$(pick '" ".join(a["verb"]+":"+a["class"] for s in j["services"] for a in s["actions"])')"
eq "a button says what it runs" "hold.sh on company/ACME-1-alpha" "$(pick 'j["tasks"][0]["actions"][0]["command"]')"

# What may run.
eq "unknown action refused" 404 "$(run '{"id":"rm-everything"}')"
eq "missing task refused" 404 "$(run '{"id":"hold-on","task":"company/nope"}')"
eq "task path with .. refused" 404 "$(run '{"id":"hold-on","task":"company/../company/ACME-1-alpha"}')"
j=$(printf '{"id":"hold-on","task":"%s"}' "$A")
eq "absolute task path refused" 404 "$(run "$j")"
eq "unknown service refused" 404 "$(run '{"id":"service-verb","service":"other","verb":"ping"}')"
eq "verb the binding does not list refused" 404 "$(run '{"id":"service-verb","service":"acme","verb":"status"}')"
eq "non-string value refused" 400 "$(run '{"id":"hold-on","task":["company/ACME-1-alpha"]}')"
eq "auto task action runs" 200 "$(run '{"id":"hold-on","task":"company/ACME-1-alpha"}')"
ok "it held the task" grep -q '^hold_merge: yes$' "$A/task.md"
eq "confirm action refused without confirmation" 428 "$(run '{"id":"hold-off","task":"company/ACME-1-alpha"}')"
ok "still held" grep -q '^hold_merge: yes$' "$A/task.md"
eq "confirm action runs when confirmed" 200 "$(run '{"id":"hold-off","task":"company/ACME-1-alpha","confirmed":true}')"
ok "hold lifted" grep -q '^hold_merge: no$' "$A/task.md"
eq "confirm service verb refused without confirmation" 428 "$(run '{"id":"service-verb","service":"acme","verb":"restart"}')"
ok "verb did not run" test ! -e "$COORD_DATA/services/restarted.txt"
eq "confirm service verb runs when confirmed" 200 "$(run '{"id":"service-verb","service":"acme","verb":"restart","confirmed":true}')"
ok "verb ran" test -e "$COORD_DATA/services/restarted.txt"
run '{"id":"service-verb","service":"acme","verb":"ping"}' >/dev/null
ok "output is returned" grep -q '"output": "pong' "$W/body"

# Records: the panel log and the task ledger get the press, never its output.
eq "sweep runs when confirmed" 200 "$(run '{"id":"sweep-task","task":"company/ACME-1-alpha","confirmed":true}')"
ok "sweep printed something" grep -q 'nothing recorded' "$W/body"
ok "press in the panel log" grep -q $'\tsweep-task\tcompany/ACME-1-alpha\t0$' "$P/log"
ok "service press in the panel log" grep -q $'\tservice-verb\tacme restart\t0$' "$P/log"
ok "press in the task ledger" grep -q $'\tpanel\tbutton sweep-task exit 0$' "$A/ledger.md"
fails 1 "no output in the panel log" grep -q 'nothing recorded\|pong' "$P/log"
fails 1 "no output in the ledger" grep -q 'nothing recorded' "$A/ledger.md"
fails 1 "refused presses not logged" grep -q 'rm-everything\|company/nope' "$P/log"

# Shell characters are values, never code.
j=$(printf '{"id":"service-verb","service":"acme;touch %s","verb":"ping"}' "$W/pwned")
eq "service name with shell characters refused" 404 "$(run "$j")"
j=$(printf '{"id":"service-verb","service":"acme","verb":"ping $(touch %s)"}' "$W/pwned")
eq "verb with shell characters refused" 404 "$(run "$j")"
odd='x$(touch pwned)`touch pwned2`;y'
mkdir -p "$COORD_DATA/tasks/company/$odd"; cp "$A/task.md" "$COORD_DATA/tasks/company/$odd/task.md"; : > "$COORD_DATA/tasks/company/$odd/ledger.md"
j=$(python3 -c 'import json,sys; print(json.dumps({"id":"hold-on","task":"company/"+sys.argv[1]}))' "$odd")
eq "task folder with shell characters runs as a plain value" 200 "$(run "$j")"
ok "and it held that folder" grep -q '^hold_merge: yes$' "$COORD_DATA/tasks/company/$odd/task.md"
ok "nothing was executed" sh -c "! ls '$W/pwned' '$S/pwned' '$S/pwned2' '$COORD_DATA/pwned' '$_TMPROOT/pwned' 2>/dev/null | grep -q ."

# The key never lands in a file other than the token file.
ok "the key is in no record" sh -c "! grep -rlF '$(tok)' '$COORD_DATA' | grep -vx '$P/token' | grep -q ."

# Every accepted request is the panel's last activity; a panel idle for twice its idle time is reaped.
ok "last request recorded" test -s "$P/last"
echo 1000 > "$P/last"; req GET /api/actions -H "X-Panel-Token: $(tok)" >/dev/null
ok "a request moves the last activity" sh -c "[ \$(cat '$P/last') -gt 1000 ]"
eq "a refused request does not" 403 "$(req GET /api/actions)"
setconf PANEL_IDLE_MIN 1
eq "reap leaves an active panel" "" "$($S/panel.sh reap)"
echo $(( $(date +%s) - 121 )) > "$P/last"
ok "reap --dry-run names the panel" grep -q '^would stop panel: no accepted request for [0-9]* min (idle limit 1 min)$' <<< "$($S/panel.sh reap --dry-run)"
ok "reap --dry-run left it running" kill -0 "$pid"
ok "reap.sh --dry-run reports it" grep -q '^would stop panel: ' <<< "$($S/reap.sh --dry-run 2>/dev/null)"
ok "reap.sh --dry-run left it running" kill -0 "$pid"
ok "reap stops it" grep -q '^stopped panel: ' <<< "$($S/panel.sh reap)"
ok "the reaped server is gone" gone "$pid"
eq "reap when stopped" "" "$($S/panel.sh reap)"
fails 2 "reap takes only --dry-run" "$S/panel.sh" reap now
start_ok "restart after reap"; echo $(( $(date +%s) - 121 )) > "$P/last"
ok "reap.sh stops it" grep -q '^stopped panel: ' <<< "$($S/reap.sh 2>/dev/null)"
ok "reap.sh left no server" gone "$pid"
setconf PANEL_IDLE_MIN 30
start_ok "start for the resource row"

# The resource row (the tracked config/resources.tsv gets the same row at integration).
printf '%s\t%s\t%s\t%s\t%s\t%s\n' panel \
  "\"\$SCRIPTS\"/panel.sh status | awk '\$1==\"running\" {n++} END {print n+0}'" 1 \
  "\"\$SCRIPTS\"/panel.sh status | awk '\$1==\"running\" {print \"panel\"}'" "\"\$SCRIPTS\"/panel.sh stop" auto \
  > "$COORD_DATA/config/resources.tsv"
eq "resource count while running" 1 "$($S/sweep.sh --run panel count)"
eq "resource list while running" panel "$($S/sweep.sh --run panel list)"
ok "resource stop" "$S/sweep.sh" --run panel stop panel
ok "the stop ended the server" gone "$pid"
eq "resource count when stopped" 0 "$($S/sweep.sh --run panel count)"

# The panel-stop button answers, then the server goes away.
start_ok "start for panel-stop"
eq "panel-stop answers" 200 "$(run '{"id":"panel-stop"}')"
ok "panel-stop ended the server" gone "$pid"
i=0; while [ -e "$P/pid" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
ok "panel-stop removed the files" test ! -e "$P/pid" -a ! -e "$P/port" -a ! -e "$P/token"

# stop leaves no process and no files.
start_ok "start for stop"
# A stop waits for a start (or stop) in progress instead of removing the files under it.
mkdir "$P/.start.lock"; "$S/panel.sh" stop >/dev/null & st=$!
i=0; while [ $i -lt 5 ]; do sleep 0.1; i=$((i + 1)); done
ok "a stop waits for the lock" sh -c "kill -0 $st && test -e '$P/pid' && kill -0 $pid"
rmdir "$P/.start.lock"; wait "$st"
ok "and then stops" gone "$pid"
start_ok "start after the waiting stop"
eq "stop" stopped "$($S/panel.sh stop)"
ok "no process after stop" gone "$pid"
ok "no files after stop" test ! -e "$P/pid" -a ! -e "$P/port" -a ! -e "$P/token"
eq "status after stop" stopped "$($S/panel.sh status)"
fails 1 "url when stopped" "$S/panel.sh" url
eq "stop when stopped" stopped "$($S/panel.sh stop)"
# A stale pid file naming another process is not a panel.
sleep 30 & other=$!; echo "$other" > "$P/pid"; echo 1 > "$P/port"
eq "a reused pid reads stopped" stopped "$($S/panel.sh status)"
$S/panel.sh stop >/dev/null; ok "stop never kills a process that is not the panel" kill -0 "$other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

# The server exits by itself when nobody asks.
setconf PANEL_IDLE_MIN 0.03
start_ok "start for the idle exit"
i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
ok "idle server exited by itself" sh -c "! kill -0 $pid 2>/dev/null"
i=0; while [ -e "$P/pid" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
ok "idle exit removed the files" test ! -e "$P/pid" -a ! -e "$P/port" -a ! -e "$P/token"

# The board is cached per kind: a live request right after a plain one rebuilds it.
setconf PANEL_IDLE_MIN 1; setconf PANEL_REFRESH_SEC 120
start_ok "start for the board cache"
mt() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$COORD_DATA/board.json"; }
req GET /api/board -H "X-Panel-Token: $(tok)" >/dev/null; m1=$(mt)
req GET /api/board -H "X-Panel-Token: $(tok)" >/dev/null
eq "a second plain request is served from the cache" "$m1" "$(mt)"
eq "a live request answers" 200 "$(req GET '/api/board?live=1' -H "X-Panel-Token: $(tok)")"
ok "a live request rebuilds the board" sh -c "[ '$(mt)' != '$m1' ]"
$S/panel.sh stop >/dev/null; setconf PANEL_REFRESH_SEC 1

# Ports: one already listening is never taken.
p=$(free_port); setconf PANEL_PORT_FROM "$p"; setconf PANEL_IDLE_MIN 1
python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(); time.sleep(30)' "$p" &
holder=$!
python3 -c 'import socket,sys,time
for _ in range(50):
    if socket.socket().connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0: break
    time.sleep(0.1)' "$p"
start_ok "start beside a busy port"
ok "a listening port is skipped" test "$PORT" != "$p"
$S/panel.sh stop >/dev/null; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
