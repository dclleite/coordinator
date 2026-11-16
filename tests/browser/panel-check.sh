#!/bin/bash
# Opt-in check of the panel page in a real browser; tests/run.sh does not run it.
# It builds a fixture, starts the panel on it, presses buttons through the browser tool and stops what it started.
#   PANEL_BROWSER  the browser command that reads a script on stdin, for example a task's wrapper:
#                  "scripts/browser.sh run <task-dir> <agent> --keep --" (its caller stops that browser).
#                  Unset: scripts/browser.sh on a fixture task, stopped and its profile removed at the end.
ORIG_PATH=$PATH
. "$(cd "$(dirname "$0")/.." && pwd -P)/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo "skipped: python3 is missing"; exit 0; }
mktask; S=$ROOT/scripts; P=$COORD_DATA/panel; W=$_TMPROOT/w; mkdir -p "$W/tools"
printf '#!/bin/bash\nexec "%s/service.sh" "$@"\n' "$S" > "$W/tools/service.sh"; chmod +x "$W/tools/service.sh"
export COORD_TOOLS=$W/tools
setconf() { grep -v "^$1=" "$COORD_ROOT/config/panel.conf" > "$W/conf"; echo "$1=$2" >> "$W/conf"; mv "$W/conf" "$COORD_ROOT/config/panel.conf"; }
port=$(python3 -c 'import random, socket
while True:
    p = random.randint(20000, 60000); s = socket.socket()
    try: s.bind(("127.0.0.1", p)); print(p); break
    except OSError: pass
    finally: s.close()')
setconf PANEL_PORT_FROM "$port"; setconf PANEL_REFRESH_SEC 1; setconf PANEL_IDLE_MIN 5

A=$($S/task-new.sh company ACME-1 alpha "Alpha task")
$S/task-set.sh "$A" needs_developer yes; $S/task-set.sh "$A" waiting_on "developer: pick a fix"
$S/hold.sh on "$A" >/dev/null
$S/agent-add.sh "$A" sub-coordinator claude m medium "$FIX" - - thr_sub >/dev/null
printf 'First handoff.\n' | $S/handoff-write.sh "$A" worker coordinator >/dev/null
printf 'Second handoff.\n' | $S/handoff-write.sh "$A" worker coordinator >/dev/null
mkdir -p "$COORD_DATA/services"
cat > "$COORD_DATA/services/toy.conf" <<'CONF'
status=printf 'degraded\nloop: last tick 39510s ago, every 1800s: stalled\n'
verb.ping=auto:echo pong
verb.slow=auto:sleep 3; echo slept
verb.restart=confirm:echo restarted
verb.restart-a=confirm:echo restarted a
verb.restart-b=confirm:echo restarted b
verb.restart-a.label=Restart part A
CONF

browser_name=""
if [ -n "${PANEL_BROWSER:-}" ]; then
  browse() { env -u COORD_ROOT -u COORD_DATA -u COORD_TOOLS PATH="$ORIG_PATH" $PANEL_BROWSER --headless --timeout 150; }
else
  browser_name=$(PATH="$ORIG_PATH" "$S/browser.sh" name "$A" panel-check)
  browse() { PATH="$ORIG_PATH" "$S/browser.sh" run "$A" panel-check -- --headless --timeout 150; }
fi
trap '"$S"/panel.sh stop >/dev/null 2>&1
  [ -z "$browser_name" ] || PATH="$ORIG_PATH" "$S"/browser.sh profile-rm "$browser_name" >/dev/null 2>&1
  _finish' EXIT

url=$($S/panel.sh start) || { echo "FAIL: the panel did not start"; exit 1; }
pid=$(cat "$P/pid")

# One script drives the page; each step reads back the page's own state, the shell then reads the logs.
sed "s|__URL__|$url|" > "$W/drive.js" <<'JS'
const page = await browser.getPage("panel-check");
await page.setViewportSize({ width: 1280, height: 900 });
await page.goto("__URL__");
await page.waitForSelector("#tasks article", { timeout: 20000 });
const r = {};
const fk = () => page.evaluate(() => { const a = document.activeElement; return a ? (a.dataset.fk || a.tagName) : ""; });
const has = (sel) => page.evaluate((s) => !!document.querySelector(s), sel);
const click = (sel) => page.click(sel, { timeout: 10000 });
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
const G = "svc:toy:confirm", ASK = '[data-fk^="ask:"]';
// Each step stops the script at its first failure and names itself, so a broken behavior reads as that step.
let failed = "";
async function step(name, fn) { if (failed) return; try { await fn(); } catch (e) { failed = name + ": " + String(e && e.message || e).split("\n")[0]; } }
await step('stalled service and the Restart choice', async () => {
  r.stalledInNeedsYou = await page.evaluate(() => [...document.querySelectorAll("#attn .attn-item .what")].some((e) => /toy: loop: last tick 11 h ago, expected every 30 min: stalled/.test(e.textContent)));
  await click('[data-fk="fold:services"]');
  await click('[data-fk="choose:' + G + '"]');
  r.chooserFocus = await fk();
  await page.keyboard.press("Escape");
  r.chooserEscapeFocus = await fk();
  r.chooserClosed = !(await has('[data-fk="pick:' + G + '"]'));
});
// A confirm option only opens its question; Escape closes it and gives focus back.
await step('a confirm option and Escape', async () => {
  await click('[data-fk="choose:' + G + '"]');
  await click('[data-fk="opt:' + G + '|service-verb||toy|restart-a"]');
  r.askFocus = await fk();
  r.askText = await page.evaluate((s) => document.querySelector(s).querySelector(".q").textContent, ASK);
  await page.keyboard.press("Escape");
  r.askEscapeFocus = await fk();
  r.askClosed = !(await has(ASK));
});
// Two clicks on "Yes" in the same instant run the action once.
await step('two clicks on Yes', async () => {
  await click('[data-fk="choose:' + G + '"]');
  await click('[data-fk="opt:' + G + '|service-verb||toy|restart"]');
  await page.evaluate(() => { const b = document.querySelector('[data-fk^="go:"]'); b.click(); b.click(); });
  await page.waitForSelector('[data-fk="dismiss:' + G + '"]', { timeout: 15000 });
});
// Enter twice on a slow button: one run, and focus stays on the running button instead of falling to the page.
await step('Enter twice on a running button', async () => {
  const slow = 'svc:toy:auto|service-verb||toy|slow';
  await page.focus('[data-fk="' + slow + '"]');
  await page.keyboard.press("Enter");
  await sleep(300);
  await page.keyboard.press("Enter");
  r.focusWhileRunning = await fk();
  r.runningAriaDisabled = await page.evaluate((s) => document.querySelector(s).getAttribute("aria-disabled"), '[data-fk="' + slow + '"]');
  await page.waitForSelector('[data-fk="dismiss:svc:toy:auto"]', { timeout: 15000 });
});
// Presses inside "Needs you" keep their result in the section's slot after the item has gone.
await step('results in Needs you', async () => {
  await click('button[data-fk^="attn:inbox|inbox-seen"]');
  await page.waitForSelector('.attn-res [data-fk="dismiss:attn:inbox"]', { timeout: 15000 });
  await sleep(3500);
  r.inboxResultKept = await has('.attn-res [data-fk="dismiss:attn:inbox"]');
  r.inboxReport = await page.evaluate(() => { const p = document.querySelector(".attn-res pre"); return p ? p.textContent : ""; });
  r.inboxItemGone = !(await has('button[data-fk^="attn:inbox|inbox-seen"]'));
  r.inboxFocus = await fk();

  await click('button[data-fk^="attn:hold:"]');
  r.holdAsk = await page.evaluate((s) => { const e = document.querySelector(s); return e ? e.querySelector(".q").textContent : ""; }, ASK);
  await click('[data-fk^="go:attn:hold:"]');
  await page.waitForSelector('.attn-res [data-fk^="dismiss:attn:hold:"]', { timeout: 15000 });
  await sleep(3500);
  r.holdResultKept = await has('.attn-res [data-fk^="dismiss:attn:hold:"]');
  r.holdItemGone = !(await has('button[data-fk^="attn:hold:"]'));
  r.holdFocus = await fk();
  await click('.attn-res [data-fk="dismiss:attn:inbox"]');
  r.dismissed = !(await has('.attn-res [data-fk="dismiss:attn:inbox"]'));
});
// Stopped from the page: the content and the live toggle no longer take input.
await step('stopped from the page', async () => {
  await click('[data-fk="fold:panel"]');
  await click('button[data-fk^="more:panel|panel-stop"]');
  await page.waitForSelector("#gone:not([hidden])", { timeout: 10000 });
  r.liveDisabled = await page.evaluate(() => document.getElementById("live").disabled);
  r.mainInert = await page.evaluate(() => document.getElementById("main").inert);
});
r.failedAt = failed;
console.log("RESULTS " + JSON.stringify(r));
JS

out=$(browse < "$W/drive.js" 2>&1); rc=$?
json=$(printf '%s\n' "$out" | sed -n 's/^RESULTS //p' | tail -1)
if [ -z "$json" ]; then echo "FAIL: the browser script did not finish (exit $rc)"; printf '%s\n' "$out" | tail -20; exit 1; fi
v() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print(v if not isinstance(v, bool) else str(v).lower())' "$json" "$1"; }
log=$P/log; svclog=$COORD_DATA/services/toy.log
eq "every step of the page ran" "" "$(v failedAt)"
n() { local c; c=$(grep -c "$1" "$2" 2>/dev/null); echo "${c:-0}"; }

eq "a degraded service with a stalled loop is in Needs you, in hours and minutes" true "$(v stalledInNeedsYou)"
eq "the Restart choice takes focus" "pick:svc:toy:confirm" "$(v chooserFocus)"
eq "Escape closes the choice and gives focus back" "choose:svc:toy:confirm true" "$(v chooserEscapeFocus) $(v chooserClosed)"
eq "a confirm option opens its question with focus" "ask:svc:toy:confirm|service-verb||toy|restart-a" "$(v askFocus)"
eq "the question names the verb by its label" "Restart part A on toy?" "$(v askText)"
eq "Escape closes the question and gives focus back" "choose:svc:toy:confirm true" "$(v askEscapeFocus) $(v askClosed)"
eq "opening the question ran nothing" 0 "$(n $'restart-a\t' "$svclog")"
eq "two clicks on Yes sent it once" 1 "$(n $'\tservice-verb\ttoy restart\t' "$log")"
eq "focus stays on the running button" "svc:toy:auto|service-verb||toy|slow true" "$(v focusWhileRunning) $(v runningAriaDisabled)"
eq "Enter twice on a running button ran it once" 1 "$(n $'\tservice-verb\ttoy slow\t' "$log")"
eq "the Mark as read result survives the refresh that removes its item" "true true" "$(v inboxResultKept) $(v inboxItemGone)"
ok "the report of what was read is shown" grep -q 'First handoff' <<< "$(v inboxReport)"
eq "the hold question names the task by its key" "Lift this task's merge hold for ACME-1?" "$(v holdAsk)"
eq "the hold result survives too" "true true" "$(v holdResultKept) $(v holdItemGone)"
eq "focus is on the latest result" "dismiss:attn:hold:company/ACME-1-alpha" "$(v holdFocus)"
eq "a result stays until dismissed" true "$(v dismissed)"
eq "stopped: the live toggle and the content take no input" "true true" "$(v liveDisabled) $(v mainInert)"
eq "each press ran once" "1 1" "$(n $'\tinbox-seen\t' "$log") $(n $'\thold-off\t' "$log")"
ok "the stop ended the server" sh -c "i=0; while kill -0 $pid 2>/dev/null && [ \$i -lt 50 ]; do sleep 0.1; i=\$((i+1)); done; ! kill -0 $pid 2>/dev/null"
