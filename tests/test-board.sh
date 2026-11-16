. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; . "$S/lib.sh"; T=$_TMPROOT/t; mkdir -p "$T/tools" "$T/none"
COORD_TOOLS=$T/none; COORD_T3=; export COORD_TOOLS COORD_T3
J=$COORD_DATA/board.json; M=$COORD_DATA/board.md
# JSON check: Python's parser when it is there, a structural check otherwise.
valid_json() {
  if command -v python3 >/dev/null 2>&1; then python3 -m json.tool "$1" >/dev/null
  else head -c 1 "$1" | grep -q '{' && tail -c 2 "$1" | grep -q '}' && grep -q '"problems": \[' "$1"; fi
}
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$J" "$1"; }
have_py=no; command -v python3 >/dev/null 2>&1 && have_py=yes

$S/board.sh
ok "empty board is JSON" valid_json "$J"
ok "empty board text" grep -q '^No open tasks\.$' "$M"
ok "no inputs: health unknown" grep -q '"health": {"verdict": "unknown", "readings": \[\]}' "$J"
ok "no inputs: services empty" grep -q '"services": \[\],' "$J"
ok "no inputs: resources empty" grep -q '"resources": \[\],' "$J"
ok "machine section without a reading" grep -q '^Verdict: unknown' "$M"

D=$($S/task-new.sh personal - quotes 'Say "hi" \ to	tabs')
$S/agent-add.sh "$D" sub-coordinator codex m medium "$FIX" - - thr_sub
$S/agent-add.sh "$D" worker codex m low "$PE/app" "$PE/app/.claude/worktrees/w1" b thr_w1 thr_sub
$S/agent-add.sh "$D" worker codex m low "$PE/app" - - thr_w2 thr_w1
printf 'worker\tcodex\tm\tlow\t%s\t-\t-\tthr_old\t-\n' "$PE/app" >> "$D/agents.tsv"
printf 'Done.\n' | $S/handoff-write.sh "$D" sub-coordinator coordinator >/dev/null
C=$($S/task-new.sh company ABC-123 c "Company")
# A record edited by hand: task-set.sh closes a task whose stage is done, so only an edit leaves it open.
sed 's/^stage: .*/stage: done/' "$C/task.md" > "$C/task.tmp" && mv "$C/task.tmp" "$C/task.md"
$S/hold.sh on --all
$S/board.sh
ok "board with a quoted title is JSON" valid_json "$J"
ok "title escaped" grep -qF '"title": "Say \"hi\" \\ to\ttabs"' "$J"
ok "old row on the board" grep -q '^- worker · codex m low · app · unknown$' "$M"
ok "old row in JSON with defaults" grep -qF '"thread": "thr_old", "parent": "-", "state": "unknown"' "$J"
ok "tree: sub-coordinator at the root" grep -q '^- sub-coordinator · codex m medium · coord · running$' "$M"
ok "tree: its worker one level down, by worktree name" grep -q '^  - worker · codex m low · w1 · running$' "$M"
ok "tree: grandchild two levels down" grep -q '^    - worker · codex m low · app · running$' "$M"
ok "hold_all" grep -q '"hold_all": true' "$J"
ok "finished not yet seen" sh -c "sed -n '/^## Finished/,/^## /p' '$M' | grep -q 'quotes · sub-coordinator · 01-sub-coordinator-to-coordinator.md'"
ok "last handoff" grep -qF '"last_handoff": {"file": "01-sub-coordinator-to-coordinator.md", "from": "sub-coordinator", "to": "coordinator"' "$J"
ok "inbox in JSON" grep -qF '"from": "sub-coordinator", "seen": false}' "$J"
ok "problem: done but open" grep -q '^- stage-done-open: ABC-123: stage is done and status is open$' "$M"
fails 1 "no stale agent yet" grep -q 'stale-agent' "$M"
ok "live empty without --live" grep -qF '"state": "running", "live": ""' "$J"
eq "sections in order" "Needs you|Running|Finished, not yet seen|Services|Machine|Problems" "$(sed -n 's/^## //p' "$M" | paste -sd'|' -)"
if [ "$have_py" = yes ]; then
  eq "task fields" "quotes personal open intake unknown False False" "$(jget '" ".join(str(t[k]) for t in d["tasks"] if t["key"]=="quotes" for k in ["key","scope","status","stage","complexity","needs_developer","hold_merge"])')"
  eq "four agents" 4 "$(jget 'len([t for t in d["tasks"] if t["key"]=="quotes"][0]["agents"])')"
fi

# Stale: no ledger or handoff activity for longer than STALE_AGENT_MIN.
touch -t 202001010000 "$D/ledger.md" "$D/handoffs" "$D"/handoffs/*
echo 'STALE_AGENT_MIN=30' >> "$COORD_ROOT/config/health.conf"
$S/board.sh
eq "three running agents stale" 3 "$(grep -c '^- stale-agent: quotes: ' "$M")"
ok "stale names the limit" grep -q 'thr_w1 is running with no ledger or handoff activity for 30 minutes' "$M"
ok "problems in JSON" grep -qF '{"kind": "stale-agent", "text": "quotes: sub-coordinator thr_sub' "$J"
ok "still JSON" valid_json "$J"

# Inputs answer: their lists land in the JSON and the text.
cat > "$T/tools/health.sh" <<'F'
#!/bin/bash
[ "${1:-}" = --json ] || exit 2
echo '{"verdict": "unhealthy", "readings": [{"name": "disk_free_gb", "value": "9", "limit": "15", "state": "LOW"}]}'
exit 1
F
cat > "$T/tools/service.sh" <<'F'
#!/bin/bash
[ "$*" = "status --all --json" ] || exit 2
echo '[{"name": "bot", "state": "ok", "detail": ["inbox 3", "watcher up"], "panel": "http://127.0.0.1:9999", "verbs": [{"verb": "restart", "class": "confirm"}]}]'
F
cat > "$T/tools/sweep.sh" <<'F'
#!/bin/bash
[ "$*" = "--orphans --json" ] || exit 2
echo '[{"kind": "browser", "count": "2", "limit": "3", "state": "ok"}]'
F
chmod +x "$T/tools"/*.sh
COORD_TOOLS=$T/tools $S/board.sh
ok "with inputs: JSON" valid_json "$J"
ok "health object kept, even on exit 1" grep -qF '"verdict": "unhealthy"' "$J"
ok "services list kept" grep -qF '"verbs": [{"verb": "restart", "class": "confirm"}]' "$J"
ok "resources list kept" grep -qF '"kind": "browser"' "$J"
ok "service on the board" grep -qF -- '- bot: ok · http://127.0.0.1:9999 · verbs: restart' "$M"
ok "service detail" grep -q '^  - watcher up$' "$M"
ok "machine verdict" grep -q '^Verdict: unhealthy$' "$M"
ok "machine reading" grep -q '^- disk_free_gb: 9 (limit 15) LOW$' "$M"
ok "resource line" grep -q '^- browser: 2 of 3 ok$' "$M"

# An input that answers something else counts as missing.
printf '#!/bin/bash\necho "not json"\n' > "$T/tools/service.sh"
printf '#!/bin/bash\nexit 3\n' > "$T/tools/sweep.sh"
COORD_TOOLS=$T/tools $S/board.sh
ok "garbage answer: services empty" grep -q '"services": \[\],' "$J"
ok "failed answer: resources empty" grep -q '"resources": \[\],' "$J"
ok "still JSON with broken inputs" valid_json "$J"

# --live fills the live field of running agents only.
printf '#!/bin/bash\necho "{\\"thread\\":{\\"threadId\\":\\"x\\",\\"status\\":\\"idle\\"},\\"messages\\":[{\\"status\\":\\"done\\"}]}"\n' > "$T/t3"; chmod +x "$T/t3"
COORD_T3=$T/t3 $S/board.sh --live
ok "live state in JSON" grep -qF '"thread": "thr_w2", "parent": "thr_w1", "state": "running", "live": "idle"' "$J"
ok "old row not asked" grep -qF '"state": "unknown", "live": ""' "$J"
ok "live state on the board" grep -q '(live: idle)$' "$M"
fails 2 "bad option" $S/board.sh --nope
eq "no temporary left" "" "$(ls -a "$COORD_DATA" | grep '^\.board-')"

# live.sh by itself.
eq "live reads the thread's own status" idle "$(COORD_T3=$T/t3 $S/live.sh thr_x)"
eq "no runtime: unknown" unknown "$(COORD_T3= $S/live.sh thr_x)"
eq "missing runtime: unknown" unknown "$(COORD_T3=$T/nothing $S/live.sh thr_x)"
printf '#!/bin/bash\nexit 1\n' > "$T/t3"
eq "failing runtime: unknown" unknown "$(COORD_T3=$T/t3 $S/live.sh thr_x)"
printf '#!/bin/bash\nexec sleep 30\n' > "$T/t3"
eq "slow runtime: unknown" unknown "$(COORD_T3=$T/t3 LIVE_TIMEOUT_SEC=1 $S/live.sh thr_x)"
fails 2 "live without an id" $S/live.sh

# A machine reading that hangs is cut at the limit, and nothing it started outlives the board.
gone() { local i=0; while pgrep -f "$1" >/dev/null; do [ $i -lt 30 ] || return 1; sleep 0.1; i=$((i+1)); done; }
mkdir -p "$T/hang"; printf '#!/bin/sh\nsleep %s &\nsleep %s\n' 4401 4402 > "$T/hang/health.sh"; chmod +x "$T/hang/health.sh"
COORD_TOOLS=$T/hang BOARD_ASK_TIMEOUT_SEC=1 $S/board.sh
ok "a hanging reading: the board is still written" grep -q '"verdict": "unknown"' "$J"
ok "a hanging reading is gone after the limit" gone 'sleep 4402'
ok "its child is gone after the limit" gone 'sleep 4401'
printf '#!/bin/sh\nsleep %s &\nsleep %s\n' 4403 4404 > "$T/hang/health.sh"
COORD_TOOLS=$T/hang $S/board.sh & bp=$!
i=0; until pgrep -f 'sleep 4403' >/dev/null || [ $i -ge 30 ]; do sleep 0.1; i=$((i+1)); done
kill -TERM "$bp"; wait "$bp" 2>/dev/null
ok "board killed: the reading is gone" gone 'sleep 4404'
ok "board killed: its child is gone" gone 'sleep 4403'
