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
Bt=$($S/task-new.sh company ACME-2 beta "Beta closed"); $S/task-set.sh "$Bt" stage done
# An abandoned task is closed at the stage it reached.
Ct=$($S/task-new.sh personal ACME-3 gamma "Gamma abandoned"); $S/task-set.sh "$Ct" stage build; $S/task-set.sh "$Ct" status closed
# Closed tasks are ordered by their last ledger write: beta is the newest.
touch -t 202601010000 "$Ct/ledger.md"; touch -t 202602010000 "$Bt/ledger.md"
mkdir -p "$COORD_DATA/services"
cat > "$COORD_DATA/services/acme.conf" <<'CONF'
status=echo ok
verb.ping=auto:echo pong
verb.ping.label=Ping it
verb.ping.label.pt-BR=Pingar
verb.restart.label.pt-BR=auto: touch ptran.txt
verb.restart=confirm:touch restarted.txt
verb.slow=auto:sleep 2; echo slept
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

# The locale tables: one file per language, every key in English, nothing the page writes left outside them.
cat > "$W/locale-check.py" <<'LOCALE_EOF'
"""Checks the panel's locale tables against the page: locale-check.py <check> <repository root>.
Prints one line per finding and exits 1 when there is any; `keys`, `placeholders`, `used`, `dead`, `literals`."""
import json
import os
import re
import sys

check, root = sys.argv[1], sys.argv[2]
page_path = os.environ.get("LOCALE_CHECK_PAGE") or os.path.join(root, "panel", "index.html")
loc = os.path.join(root, "panel", "locales")
page = open(page_path, encoding="utf-8").read()
m = re.search(r'<script nonce="__PANEL_NONCE__">\n(.*?)\n</script>', page, re.S)
# Comments are prose for the next reader, not words the page writes.
script = re.sub(r"/\*.*?\*/|(^|\s)//[^\n]*", r"\1", m.group(1) if m else "", flags=re.S)
LITERAL = r'"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\'|`((?:[^`\\]|\\.)*)`'
literals = [next((g for g in m if g), "") for m in re.findall(LITERAL, script)]
KEY = re.compile(r"[a-z][A-Za-z]*(\.[A-Za-z0-9_-]+)+")
style = re.search(r"<style>(.*?)</style>", page, re.S).group(1)
tables = {n[:-5]: json.load(open(os.path.join(loc, n), encoding="utf-8"))
          for n in sorted(os.listdir(loc)) if n.endswith(".json")}
en = tables["en"]
out = []

# Keys built from a prefix and a value: each prefix lists where its values come from.
actions = [l.split("\t")[0] for l in open(os.path.join(root, "config", "panel-actions.tsv"), encoding="utf-8")
           if l.strip() and not l.startswith("#")]
server = open(os.path.join(root, "scripts", "panel-server.py"), encoding="utf-8").read()
codes = set(re.findall(r'"code": "([a-z-]+)"', server)) | set(re.findall(r'self\.refuse\(\d+, "[^"]*", "([a-z-]+)"\)', server))
health = open(os.path.join(root, "scripts", "health.sh"), encoding="utf-8").read()
kinds = [l.split("\t")[0] for l in open(os.path.join(root, "config", "resources.tsv"), encoding="utf-8")
         if l.strip() and not l.startswith("#")]
stages = json.loads(re.search(r"const STAGES = (\[[^\]]*\]);", script).group(1))
dynamic = {
    "state.": ["running", "waiting", "done", "failed", "stopped", "unknown"],
    "stage.": stages + ["unknown"],
    "svcstate.": ["ok", "degraded", "down", "unknown"],
    "loopstate.": re.search(r"every \(\\d\+\) \?s\(\?:: \(([a-z|]+)\)", script).group(1).split("|"),
    "action.": [a + s for a in actions for s in (".label", ".note", ".hint")],
    "kind.": [k + s for k in kinds for s in (".one", ".other")],
    "server.": sorted(codes),
    "reading.": re.findall(r"^report ([a-z_]+) ", health, re.M) + kinds,
    "meter.": re.findall(r"^report [a-z_]+ .* ([A-Z]+)(?: unknown-ok)?$", health, re.M),
}
# A note is optional, and so is a reading's or a meter word's name: the page falls back to the data.
optional = ("action.", "server.", "reading.", "meter.", "kind.")
plural_suffix = re.compile(r"\.(zero|one|two|few|many|other)$")


def asked():
    """Keys the page names (a plural by its .other form), and the prefixes it builds keys from ("state." + s)."""
    static = {k for k in literals if KEY.fullmatch(k)}
    static |= set(re.findall(r'data-i18n(?:-title|-aria)?="([^"]+)"', page))
    static = {k + ".other" if k not in en and k + ".other" in en else k for k in static}
    prefixes = set(re.findall(r'"([a-z][A-Za-z-]*\.)"\s*\+', script))
    return static, prefixes


if check == "keys":
    for lang, t in tables.items():
        for k in sorted(set(en) - set(t)):
            out.append("%s lacks %s" % (lang, k))
        for k in sorted(set(t) - set(en)):
            out.append("%s has %s, which en lacks" % (lang, k))
        for k, v in t.items():
            if not isinstance(v, str) or not v.strip():
                out.append("%s %s is empty or not text" % (lang, k))
elif check == "placeholders":
    for lang, t in tables.items():
        for k in sorted(set(en) & set(t)):
            a, b = set(re.findall(r"\{[a-z]+\}", en[k])), set(re.findall(r"\{[a-z]+\}", t[k]))
            if a != b:
                out.append("%s %s: placeholders %s, en has %s" % (lang, k, sorted(b), sorted(a)))
elif check == "used":
    static, prefixes = asked()
    for k in sorted(static):
        if k not in en and not any(k.startswith(p) for p in dynamic):
            out.append("the page asks for %s, which en lacks" % k)
    for p in sorted(prefixes):
        if p not in dynamic:
            out.append("the page builds keys from %s, which this check cannot list" % p)
        elif not p.startswith(optional):
            for v in dynamic[p]:
                if p + v not in en:
                    out.append("the page may ask for %s%s, which en lacks" % (p, v))
    for a in actions:
        if "action.%s.label" % a not in en:
            out.append("action %s of config/panel-actions.tsv has no label in en" % a)
elif check == "dead":
    static, prefixes = asked()
    for k in sorted(en):
        if k in static or plural_suffix.sub("", k) + ".other" in static and plural_suffix.search(k):
            continue
        p = next((p for p in prefixes if k.startswith(p)), None)
        if p and p in dynamic and k[len(p):] in dynamic[p]:
            continue
        out.append("en has %s, which the page never asks for" % k)
elif check == "literals":
    # A literal is user-facing English unless every word in it is page machinery: a class of the style sheet, a key,
    # or a word of the DOM, the events and the data this page reads. What this cannot see: English that reaches the
    # page from data, words inside a regular expression, and a word that is also on this list.
    classes = set(re.findall(r"\.([a-z][a-z0-9-]*)", style))
    machine = classes | set(re.findall(r"\b([a-z]+)\b", style))
    machine |= set("""
        a b i p ul li dl dt dd div span code pre summary details button article iframe h2 h3 meta name content panel
        token refresh idle use strict string click change keydown toggle visibilitychange true false aria disabled
        expanded label role img status group hidden busy live polite inert Escape Enter POST GET X Panel Token
        Content Type application json cache no store api board actions run key fold fk ask go pick opt choose nopick
        dismiss res exp frame svc attn inbox holdall hold task more cleanup global tasks services verb until confirmed
        auto confirm unknown running waiting done failed stopped degraded down ok healthy unhealthy resource gb pct mem
        memory free stalled failing error developer you not intake align build review demo ship watch seen detail
        keep start end block noopener noreferrer blank referrer self href http https protocol digit numeric short
        month day hour minute second maximumFractionDigits replace notRead LOW HIGH lock warn reap preview sweep
        locale lang strings scripts sh url health on off all stop restart every ago s detail tick zero other note en
        data i18n title px disk
        """.split())
    machine |= set(re.findall(r'\bid="([a-z-]+)"', page)) | set(re.findall(r'fold\("([a-z]+)"', script))
    for s in literals:
        if not s or KEY.fullmatch(s) or re.fullmatch(r"\.?[a-z][A-Za-z-]*\.?", s) and (s.strip(".") in machine or "." in s):
            continue          # empty, a table key, or a piece of one
        words = re.findall(r"[A-Za-z]{2,}", s)
        # Words with a space between them are a class list or a sentence: only the style sheet's classes pass.
        sentence = re.search(r"[A-Za-z] +[A-Za-z]", s) and not re.fullmatch(r"scripts/[a-z-]+\.sh [a-z]+", s)
        allowed = classes | {"use", "strict", "confirm", "noopener", "noreferrer"} if sentence else machine
        # A capital marks a word for people unless it is a key name, a header or a reading state the data carries.
        caps = {"Escape", "Enter", "POST", "Panel", "Token", "Content", "Type", "LOW", "HIGH", "GB"}
        foreign = [w for w in words if (w not in caps if w[0].isupper() else w not in allowed)]
        if foreign:
            out.append("English left in the page's script: %r" % s)
    body = re.sub(r"<script.*?</script>|<style>.*?</style>|<[^>]+>", " ", page[page.index("<body>"):], flags=re.S)
    for word in re.findall(r"[A-Za-z]{2,}[^<>]*", body):
        out.append("text in the page's markup: %r" % word.strip())
    title = re.search(r"<title[^>]*>(.*?)</title>", page, re.S).group(1)
    if title.strip():
        out.append("text in the page's title: %r" % title)
else:
    sys.exit("unknown check: %s" % check)
for line in out:
    print(line)
sys.exit(1 if out else 0)
LOCALE_EOF
lc() { python3 "$W/locale-check.py" "$1" "$ROOT"; }
ok "every table has exactly the keys of en, none empty" lc keys
ok "every key has the same placeholders in every table" lc placeholders
ok "every key the page asks for is in en, and every action has a label" lc used
ok "every key of en is one the page asks for" lc dead
ok "no English literal left in the page's script or markup" lc literals
eq "the shipped tables" "en.json pt-BR.json" "$(ls "$ROOT/panel/locales" | paste -sd' ' -)"
# A service's loop line, run through the page's own word functions: the recognized fragment and the state word that
# ends it come from the table; the rest of the line stays the service's.
cat > "$W/words.py" <<'WORDS_EOF'
import json, re, sys
panel, lang, line, extra = sys.argv[1:5]
page = open(panel + "/index.html", encoding="utf-8").read()
strings = json.load(open(panel + "/locales/en.json", encoding="utf-8"))
if lang != "en":
    strings.update(json.load(open("%s/locales/%s.json" % (panel, lang), encoding="utf-8")))
strings.update(json.loads(extra))
def function(name):
    start = page.index("\nfunction %s(" % name) + 1
    depth, k = 0, page.index("{", start)
    while True:
        depth += {"{": 1, "}": -1}.get(page[k], 0); k += 1
        if depth == 0:
            return page[start:k]
js = ["const LANG = %s, STR = %s;" % (json.dumps(lang), json.dumps(strings)),
      re.search(r"const PLURAL = .*;", page).group(0)]
js += [function(n) for n in ("num", "has", "fill", "t", "tn", "dur", "humanize")]
js.append("console.log(humanize(%s));" % json.dumps(line))
print("\n".join(js))
WORDS_EOF
words() { local extra=${3:-}; [ -n "$extra" ] || extra='{}'
  python3 "$W/words.py" "$ROOT/panel" "$1" "$2" "$extra" > "$W/words.js" && node "$W/words.js"; }
if command -v node >/dev/null 2>&1; then
  eq "en: the loop line reads as before" "nudge: last tick 13 h ago, expected every 30 min: stalled" \
    "$(words en 'nudge: last tick 47950s ago, every 1800s: stalled')"
  eq "pt-BR: the loop fragment and its state word are in Portuguese" "nudge: último tick há 13 h, esperado a cada 30 min: parado" \
    "$(words pt-BR 'nudge: last tick 47950s ago, every 1800s: stalled')"
  eq "pt-BR: failing and error too" "a: último tick há 5 s, esperado a cada 1 min: falhando | b: último tick há 2 min, esperado a cada 1 min: erro" \
    "$(words pt-BR 'a: last tick 5s ago, every 60s: failing | b: last tick 120s ago, every 60s: error')"
  eq "pt-BR: a loop line with no state word" "mention: último tick há 2 s, esperado a cada 1 min" "$(words pt-BR 'mention: last tick 2s ago, every 60s')"
  eq "en: a loop line with no state word" "mention: last tick 2 s ago, expected every 1 min" "$(words en 'mention: last tick 2s ago, every 60s')"
  eq "the fragment and the state word are the table's" "<F 13 h ago 30 min>: <S>" \
    "$(words pt-BR 'nudge: last tick 47950s ago, every 1800s: stalled' '{"svc.lastTick":"<F {ago} {every}>","time.ago":"{d} ago","loopstate.stalled":"<S>"}' | sed 's/^nudge: //')"
  eq "pt-BR: a word the page does not recognize stays the service's" "nudge: último tick há 13 h, esperado a cada 30 min: paused" \
    "$(words pt-BR 'nudge: last tick 47950s ago, every 1800s: paused')"
  eq "pt-BR: other service lines keep their words, durations follow the language" "panel: signal fresh, 19 s; watcher: running, 52 MB" \
    "$(words pt-BR 'panel: signal fresh, 19s; watcher: running, 52 MB')"
else
  echo "loop line checks skipped: node is missing"
fi
# The language: auto follows the browser's languages, a base language matching too; English otherwise.
page_lang() {
  if [ -n "${1:-}" ]; then req GET "/?key=$(tok)" -H "Accept-Language: $1" >/dev/null; else req GET "/?key=$(tok)" >/dev/null; fi
  sed -n 's/^<html lang="\([^"]*\)">$/\1/p' "$W/body"
}
locale() { python3 -c 'import json,re,sys
m = re.search(r"<script type=.application/json. id=.panel-locale.>(.*?)</script>", open(sys.argv[1]).read(), re.S)
print(eval(sys.argv[2], {"d": json.loads(m.group(1))}))' "$W/body" "$1"; }
eq "auto without a browser language is English" en "$(page_lang)"
eq "the English page carries the English table" "Needs you" "$(locale 'd["strings"]["sec.needs"]')"
eq "auto takes pt-BR" pt-BR "$(page_lang 'pt-BR,en;q=0.8')"
eq "the Portuguese page carries the Portuguese table" "Precisa de você" "$(locale 'd["strings"]["sec.needs"]')"
eq "auto takes the base language: pt" pt-BR "$(page_lang pt)"
eq "auto takes the base language: pt-PT" pt-BR "$(page_lang 'pt-PT')"
eq "auto takes the first language a table exists for" pt-BR "$(page_lang 'fr-FR, fr;q=0.9, pt;q=0.5, en;q=0.3')"
eq "auto follows the weights, not the order" en "$(page_lang 'pt;q=0.2, en;q=0.9')"
eq "a language refused with q=0 is never taken" en "$(page_lang 'pt;q=0, de')"
eq "a language with no table is English" en "$(page_lang 'de-DE,de')"
# What the page does when pressed (running guard, Escape, focus, results that survive a refresh) is checked in a
# browser by tests/browser/panel-check.sh, run by hand.

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
eq "the ledger tail is the last 8 lines" "8 line 3 line 10" "$(bj '(lambda l: "%d %s %s" % (len(l), l[0]["text"], l[-1]["text"]))(j["panel"]["ledgers"]["company/ACME-1-alpha"])')"
eq "board carries closed tasks, newest first, with their stage" "company/ACME-2-beta:Beta closed:done personal/ACME-3-gamma:Gamma abandoned:build" \
  "$(bj '" ".join(c["task"]+":"+c["title"]+":"+c["stage"] for c in j["panel"]["closed"])')"
# A rebuild that fails is said, not served as current.
chmod a-w "$COORD_DATA"; sleep 1.1
req GET /api/board -H "X-Panel-Token: $(tok)" >/dev/null
chmod u+w "$COORD_DATA"
eq "board says when rebuilding it failed" False "$(bj 'j["panel"]["rebuilt"]')"
ok "no cross-origin header on an answer" sh -c "! grep -qi '^access-control-' '$W/hdr'"
eq "actions answer" 200 "$(req GET /api/actions -H "X-Panel-Token: $(tok)")"
cp "$W/body" "$W/actions"
pick() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"j": json.load(open(sys.argv[2]))}))' "$1" "$W/actions"; }
eq "global buttons" "refresh inbox-seen hold-all-on reap-preview reap panel-stop" "$(pick '" ".join(a["id"] for a in j["global"])')"
eq "a task at intake with no branch and nothing left running has no button" "company/ACME-1-alpha: " "$(pick '"; ".join(t["task"]+": "+" ".join(a["id"] for a in t["actions"]) for t in j["tasks"])')"
eq "service verbs take the binding's class" "ping:auto restart:confirm slow:auto" "$(pick '" ".join(a["verb"]+":"+a["class"] for s in j["services"] for a in s["actions"])')"
eq "a binding's label names the verb, else the table's label" "Ping it|Run restart|Run slow" "$(pick '"|".join(a["label"] for s in j["services"] for a in s["actions"])')"
eq "a binding's labels per language go to the page" "ping:=Ping it,pt-BR=Pingar restart:pt-BR=auto: touch ptran.txt slow:" \
  "$(pick '" ".join(a["verb"]+":"+",".join(k+"="+v for k, v in sorted(a["verb_labels"].items())) for s in j["services"] for a in s["actions"])')"

# What a task's stop button offers: open rows still alive, with a stop command, not protected by a service.
# Fake kinds list and stop lines of files under $DATA/fake; every listing of fakeauto adds a line to its calls file.
FK=$COORD_DATA/fake; mkdir -p "$FK" "$COORD_DATA/config"
printf 'b1\nb2\na1\nguarded-1\nlate\n' > "$FK/fakeauto"; printf 'c1\n' > "$FK/fakebox"; printf 'n1\n' > "$FK/nostop"
fake_row() { # <kind> <stop: yes|no> <class>
  local stop=-; [ "$2" = yes ] && stop="grep -vxF {id} \"\$DATA/fake/$1\" > \"\$DATA/fake/$1.t\"; mv \"\$DATA/fake/$1.t\" \"\$DATA/fake/$1\""
  printf '%s\techo 0\t-\t%s\t%s\t%s\n' "$1" "echo x >> \"\$DATA/fake/calls.$1\"; cat \"\$DATA/fake/$1\"" "$stop" "$3"; }
{ fake_row fakeauto yes auto; fake_row fakebox yes confirm; fake_row nostop no auto
  printf 'deaf\techo 0\t-\texit 1\ttrue\tauto\n'; } > "$COORD_DATA/config/resources.tsv"
printf 'protect=guarded-1\nthreads=thr_loop1, thr_loop2\n' >> "$COORD_DATA/services/acme.conf"
D=$($S/task-new.sh personal ACME-4 delta "Delta task")
for r in "fakeauto b1" "fakeauto b2" "fakebox c1" "nostop n1" "deaf d1" "fakeauto guarded-1" "fakeauto gone-1"; do
  $S/resource-add.sh "$D" $r >/dev/null; done
$S/resource-add.sh "$A" fakeauto a1 >/dev/null
E=$($S/task-new.sh personal ACME-5 echo "Echo task"); $S/resource-add.sh "$E" deaf e1 >/dev/null; $S/resource-add.sh "$E" nostop n1 >/dev/null
# Service loops on delta: two rows whose threads the binding names, beside one agent of the task's own.
$S/agent-add.sh "$D" worker codex m medium "$PE/app" - - thr_d >/dev/null
$S/agent-add.sh "$D" worker codex m medium "$PE/app" - - thr_loop1 >/dev/null
$S/agent-add.sh "$D" worker codex m medium "$PE/app" - - thr_loop2 >/dev/null; $S/agent-set.sh "$D" thr_loop2 state waiting >/dev/null
sleep 1.1; rm -f "$FK"/calls.*
req GET /api/actions -H "X-Panel-Token: $(tok)" >/dev/null; cp "$W/body" "$W/actions"
eq "one listing per kind per refresh, not one per task" 1 "$(wc -l < "$FK/calls.fakeauto" | tr -d ' ')"
items() { pick '" ".join(i["kind"]+":"+i["id"] for t in j["tasks"] if t["task"]=="'"$1"'" for a in t["actions"] if a["id"]=="sweep-task" for i in a["items"])'; }
eq "the stop button lists what is alive, with a stop command, not protected" "fakeauto:b1 fakeauto:b2 fakebox:c1" "$(items personal/ACME-4-delta)"
eq "another task's alive row is its own" "fakeauto:a1" "$(items company/ACME-1-alpha)"
eq "a listing that does not answer and a kind with no stop command offer nothing" "personal/ACME-5-echo: " \
  "$(pick '"; ".join(t["task"]+": "+" ".join(a["id"] for a in t["actions"]) for t in j["tasks"] if t["task"]=="personal/ACME-5-echo")')"
eq "the stop button says it confirms what asks first" "sweep.sh personal/ACME-4-delta --confirmed" \
  "$(pick '[a["command"] for t in j["tasks"] if t["task"]=="personal/ACME-4-delta" for a in t["actions"] if a["id"]=="sweep-task"][0]')"
eq "a press with nothing left to stop is refused" 410 "$(run '{"id":"sweep-task","task":"personal/ACME-5-echo","confirmed":true}')"
ok "with a code the page translates" grep -q '"code": "nothing-to-stop"' "$W/body"
eq "refused before it asks" 410 "$(run '{"id":"sweep-task","task":"personal/ACME-5-echo"}')"
ok "and logged as refused" grep -q $'\tconfirm\tsweep-task\tpersonal/ACME-5-echo\trefused$' "$P/log"
eq "the stop asks first" 428 "$(run '{"id":"sweep-task","task":"personal/ACME-4-delta"}')"
ok "and asking stopped nothing" grep -qx c1 "$FK/fakebox"
eq "a confirmed stop runs" 200 "$(run '{"id":"sweep-task","task":"personal/ACME-4-delta","confirmed":true}')"
ok "it reached sweep.sh with --confirmed: what asks first is stopped" grep -q 'fakebox c1: stopped' "$W/body"
fails 1 "the confirm-class fixture is gone" grep -qx c1 "$FK/fakebox"
ok "one line per item as sweep.sh prints it" grep -q 'fakeauto b1: stopped.*fakeauto b2: stopped' "$W/body"
ok "the protected one is kept" grep -qx guarded-1 "$FK/fakeauto"
eq "nothing left: the button is gone" "" "$(req GET /api/actions -H "X-Panel-Token: $(tok)" >/dev/null; cp "$W/body" "$W/actions"; items personal/ACME-4-delta)"
eq "and a press is refused" 410 "$(run '{"id":"sweep-task","task":"personal/ACME-4-delta","confirmed":true}')"
# A row recorded after the board was read still counts at the press: the server lists again.
$S/resource-add.sh "$E" fakeauto late >/dev/null
eq "the press lists again instead of trusting the board" 200 "$(run '{"id":"sweep-task","task":"personal/ACME-5-echo","confirmed":true}')"
ok "and stopped it" grep -q 'fakeauto late: stopped' "$W/body"

# The block button: a branch or a merge request, at a stage from build to ship; lifting is offered on any held task.
hold_ids() { req GET /api/actions -H "X-Panel-Token: $(tok)" >/dev/null; cp "$W/body" "$W/actions"
  pick '" ".join(a["id"] for t in j["tasks"] if t["task"]=="'"$1"'" for a in t["actions"] if a["id"].startswith("hold"))'; }
$S/task-set.sh "$D" stage build
eq "build with no branch and no merge request: no block" "" "$(hold_ids personal/ACME-4-delta)"
$S/agent-add.sh "$D" worker codex m medium "$PE/app" - feature-x thr_b >/dev/null
eq "build with a branch: block" hold-on "$(hold_ids personal/ACME-4-delta)"
for st in review demo developer-review ship; do $S/task-set.sh "$D" stage "$st"; eq "$st with a branch: block" hold-on "$(hold_ids personal/ACME-4-delta)"; done
for st in intake align watch cleanup; do $S/task-set.sh "$D" stage "$st"; eq "$st with a branch: no block" "" "$(hold_ids personal/ACME-4-delta)"; done
$S/task-set.sh "$E" stage ship; $S/task-set.sh "$E" merge_requests "!7"
eq "ship with a merge request and no branch: block" hold-on "$(hold_ids personal/ACME-5-echo)"
$S/task-set.sh "$E" stage intake; $S/hold.sh on "$E" >/dev/null
eq "a held task at intake offers the lift" hold-off "$(hold_ids personal/ACME-5-echo)"
$S/hold.sh off "$E" >/dev/null; $S/task-set.sh "$D" stage build
hold_ids personal/ACME-4-delta >/dev/null
eq "a button says what it runs" "hold.sh on personal/ACME-4-delta" \
  "$(pick '[a["command"] for t in j["tasks"] if t["task"]=="personal/ACME-4-delta" for a in t["actions"] if a["id"]=="hold-on"][0]')"

# A service's loops: marked with the service on the board, and left out of what the page counts.
req GET /api/board -H "X-Panel-Token: $(tok)" >/dev/null
eq "the board marks a bound thread with its service" "thr_d: thr_loop1:acme thr_loop2:acme thr_b:" \
  "$(bj '" ".join(a["thread"]+":"+a.get("service","") for x in j["tasks"] if x["key"]=="ACME-4" for a in x["agents"])')"
if command -v node >/dev/null 2>&1; then
  python3 - "$ROOT/panel/index.html" > "$W/count.js" <<'COUNT_EOF'
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
fns = [re.search(r"\nfunction %s\(.*" % n, page).group(0).strip() for n in ("ownAgents", "loopsOf")]
print("\n".join(fns) + """
const x = { agents: [{ state: "running" }, { state: "running", service: "acme" }, { state: "waiting", service: "acme" }, { state: "done" }] };
console.log(ownAgents(x).length, ownAgents(x).filter((a) => a.state === "running").length, [...loopsOf(x)].join(";"));""")
COUNT_EOF
  eq "the page counts the task's own agents, and the loops apart per service" "2 1 acme,2" "$(node "$W/count.js")"
  eq "every count and tree of agents goes through ownAgents or loopsOf" "ownAgents loopsOf" \
    "$(grep -F '.agents' "$H" | sed -n 's/^function \([A-Za-z]*\)(.*/\1/p' | paste -sd' ' -)"
  eq "and nothing else reads a task's agents" 2 "$(grep -cF '.agents' "$H")"
else
  echo "page count checks skipped: node is missing"
fi

# What may run.
eq "unknown action refused" 404 "$(run '{"id":"rm-everything"}')"
ok "a refusal carries a code the page translates" grep -q '"code": "no-action"' "$W/body"
eq "a language's label line is never a verb" 404 "$(run '{"id":"service-verb","service":"acme","verb":"restart.label.pt-BR","confirmed":true}')"
ok "and its text never ran" test ! -e "$COORD_DATA/services/ptran.txt"
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
ok "press in the panel log" grep -q $'\tsweep-task\tpersonal/ACME-4-delta\t0$' "$P/log"
ok "service press in the panel log" grep -q $'\tservice-verb\tacme restart\t0$' "$P/log"
ok "press in the task ledger" grep -q $'\tpanel\tbutton sweep-task exit 0$' "$D/ledger.md"
fails 1 "no output in the panel log" grep -q 'stopped\|pong' "$P/log"
fails 1 "no output in the ledger" grep -q 'stopped' "$D/ledger.md"
ok "a refused press is logged with class, action, target and refused" grep -q $'\tconfirm\thold-off\tcompany/ACME-1-alpha\trefused$' "$P/log"
ok "an unknown action is logged as refused" grep -q $'\t-\trm-everything\t-\trefused$' "$P/log"
ok "a press is logged with its class" grep -q $'\tconfirm\tsweep-task\tpersonal/ACME-4-delta\t0$' "$P/log"
j=$(python3 -c 'import json; print(json.dumps({"id":"hold-on","task":"company/x\ty\nz"}))')
run "$j" >/dev/null
eq "a refused value cannot add a line or a field to the log" 0 "$(awk -F'\t' 'NF != 5' "$P/log" | wc -l | tr -d ' ')"

# The same action on the same target never runs twice at once.
curl -s -o /dev/null -X POST -H "X-Panel-Token: $(tok)" -H 'Content-Type: application/json' \
  --data-binary '{"id":"service-verb","service":"acme","verb":"slow"}' "http://127.0.0.1:$PORT/api/run" & slow=$!
i=0; until grep -q 'sleep 2' <<< "$(ps -A -o args=)" || [ $i -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
eq "a second press while it runs is refused" 409 "$(run '{"id":"service-verb","service":"acme","verb":"slow"}')"
ok "with the code the page translates" grep -q '"code": "already-running"' "$W/body"
eq "another target runs meanwhile" 200 "$(run '{"id":"service-verb","service":"acme","verb":"ping"}')"
wait "$slow"
eq "it ran once" 1 "$(grep -c $'\tservice-verb\tacme slow\t0$' "$P/log")"
ok "the second press is logged as refused" grep -q $'\tauto\tservice-verb\tacme slow\trefused$' "$P/log"
eq "and it runs again once done" 200 "$(run '{"id":"service-verb","service":"acme","verb":"slow"}')"

# Mark as read marks only what the page listed: the handoffs up to the time it sends.
printf 'First.\n' | COORD_NOW=2026-03-01T10:00:00+00:00 $S/handoff-write.sh "$A" worker coordinator >/dev/null
printf 'Second.\n' | COORD_NOW=2026-03-01T11:00:00+00:00 $S/handoff-write.sh "$A" worker coordinator >/dev/null
eq "mark as read needs the time" 400 "$(run '{"id":"inbox-seen"}')"
eq "a time of another shape is refused" 400 "$(run '{"id":"inbox-seen","until":"2026-03-01 10:00"}')"
eq "anything after the time is refused" 400 "$(run '{"id":"inbox-seen","until":"2026-03-01T10:00:00+00:00 --peek"}')"
eq "mark as read runs" 200 "$(run '{"id":"inbox-seen","until":"2026-03-01T10:30:00+00:00"}')"
ok "it reports what it marked" grep -q 'First\.' "$W/body"
fails 1 "and not the later one" grep -q 'Second\.' "$W/body"
eq "one handoff stays unread" 1 "$(awk -F'\t' '$5=="0"' "$COORD_DATA/inbox.tsv" | wc -l | tr -d ' ')"
ok "the later one" grep -q 'Second\.' "$A/handoffs/$(awk -F'\t' '$5=="0" {print $3}' "$COORD_DATA/inbox.tsv")"

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
# The panel in use is the coordinator's own, not a leftover; once idle past twice its idle time it is one.
eq "a panel in use is no orphan" "nothing orphaned" "$($S/sweep.sh --orphans)"
ok "nor on the board" python3 -c 'import json,sys; assert all(r["orphans"] == [] for r in json.loads(sys.argv[1]) if r["kind"] == "panel")' "$($S/sweep.sh --orphans --json)"
fails 1 "nor in the cleanup preview" grep -q 'panel' <<< "$($S/reap.sh --dry-run 2>/dev/null)"
cp "$P/last" "$W/last"; echo $(( $(date +%s) - 3700 )) > "$P/last"
eq "an idle panel is an orphan" "$(printf 'panel\tpanel')" "$($S/sweep.sh --orphans)"
ok "and the cleanup preview names it" grep -q '^would stop panel: ' <<< "$($S/reap.sh --dry-run 2>/dev/null)"
cp "$W/last" "$P/last"
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

# The private file overrides the tracked one key by key; an unknown language never starts a server.
mkdir -p "$COORD_DATA/config"; MY=$COORD_DATA/config/panel.conf
setconf PANEL_IDLE_MIN 1
printf 'PANEL_LANG=pt-BR\n' > "$MY"
start_ok "start with a private language"
eq "the private language wins over the tracked auto" pt-BR "$(page_lang 'en-US,en')"
$S/panel.sh stop >/dev/null
setconf PANEL_LANG pt-BR; printf 'PANEL_LANG=en\n' > "$MY"
start_ok "start with the private file naming English"
eq "the private file wins over the tracked file" en "$(page_lang 'pt-BR')"
$S/panel.sh stop >/dev/null
setconf PANEL_LANG auto; printf 'PANEL_REFRESH_SEC=7\n' > "$MY"
start_ok "start with a private refresh"
req GET "/?key=$(tok)" >/dev/null
ok "a private key is read" grep -q '<meta name="panel-refresh" content="7">' "$W/body"
eq "and the tracked ones still apply" pt-BR "$(page_lang pt)"
$S/panel.sh stop >/dev/null
for bad in xx-YY '../en' 'pt BR'; do
  printf 'PANEL_LANG=%s\n' "$bad" > "$MY"
  fails 2 "an unknown PANEL_LANG ($bad) is refused at start" "$S/panel.sh" start
done
printf 'PANEL_LANG=xx-YY\n' > "$MY"
ok "the refusal names the tables that exist" sh -c "'$S/panel.sh' start 2>&1 | grep -qF 'PANEL_LANG=xx-YY has no table; use auto or one of: en, pt-BR'"
eq "nothing started" stopped "$($S/panel.sh status)"
rm "$MY"
# The server itself: a key missing from a table, or left empty, falls back to English; a text is data, never markup.
mkdir -p "$W/loc"
printf '{"a": "A en", "b": "B en", "c": "C en", "x": "</script><script>alert(1)</script>"}\n' > "$W/loc/en.json"
printf '{"a": "A pt", "b": "  ", "x": "<b>&</b>"}\n' > "$W/loc/pt-BR.json"
srv() { python3 "$S/panel-server.py" --data "$COORD_DATA" --scripts "$S" --page "$ROOT/panel/index.html" \
  --actions "$COORD_ROOT/config/panel-actions.tsv" --locales "$W/loc" --lang "$1" --token-file "$W/tk" \
  --port-from "$(free_port)" --idle-min 1 --refresh-sec 1; }
echo testkey > "$W/tk"
fails 2 "the server refuses a language with no table" srv fr
srv pt-BR >/dev/null 2>&1 & i=0; while [ ! -s "$P/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
PORT=$(cat "$P/port"); req GET "/?key=testkey" >/dev/null
eq "a key the table has is its own" "A pt" "$(locale 'd["strings"]["a"]')"
eq "a key the table lacks is English" "C en" "$(locale 'd["strings"]["c"]')"
eq "a key the table leaves empty is English" "B en" "$(locale 'd["strings"]["b"]')"
fails 1 "a table's text cannot close the page's script" grep -qF '</script><script>alert' "$W/body"
fails 1 "nor add markup" grep -qF '<b>&' "$W/body"
ok "the locale block holds no raw <, > or &" python3 -c 'import re,sys
b = re.search(r"id=.panel-locale.>(.*?)</script>", open(sys.argv[1]).read(), re.S).group(1)
sys.exit(1 if re.search("[<>&]", b) else 0)' "$W/body"
eq "it reaches the page as the same text" "<b>&</b>" "$(locale 'd["strings"]["x"]')"
rm "$W/loc/pt-BR.json"; req GET "/?key=testkey" >/dev/null
eq "a table removed while running falls back to English" "en A en" "$(locale 'd["lang"] + " " + d["strings"]["a"]')"
$S/panel.sh stop >/dev/null

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
