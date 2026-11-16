. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"
# Resource kinds of the fixture: one listed by a file, one that cannot be listed, one needing confirmation,
# and a pid-file kind stopped by another script of the repository (the shape of a local server row).
L=$FIX/alive.txt; : > "$L"; export L
mkdir -p "$FIX/scripts"
cat > "$FIX/config/resources.tsv" <<'T'
# kind	count_cmd	limit	list_cmd	stop_cmd	class
thing	grep -c . "$L" || true	2	cat "$L"	grep -vxF "$RES_ID" "$L" > "$L.n"; mv "$L.n" "$L"; echo "{id}" >> "$ROOT/stops.log"	auto
blind	echo 0	-	-	echo "{id}" >> "$ROOT/stops.log"	auto
careful	echo 1	5	echo c1	echo "{id}" >> "$ROOT/stops.log"	confirm
widget	[ -f "$DATA/widget.pid" ] && kill -0 "$(cat "$DATA/widget.pid")" 2>/dev/null && echo 1 || echo 0	1	cat "$DATA/widget.pid" 2>/dev/null || true	"$ROOT"/scripts/widget.sh stop	auto
T
printf '#!/bin/bash\n[ "$1" = stop ] || exit 2\nkill "$(cat "$DATA/widget.pid")" && rm -f "$DATA/widget.pid"\n' > "$FIX/scripts/widget.sh"
chmod +x "$FIX/scripts/widget.sh"
D=$($S/task-new.sh personal - res "Res")

# resource-add / resource-done
fails 2 "unknown kind refused" $S/resource-add.sh "$D" nope x
fails 2 "tab in id refused" $S/resource-add.sh "$D" thing "a$(printf '\t')b"
ok "add" $S/resource-add.sh "$D" thing t1 thr_1
eq "row" "thing|t1|thr_1|-" "$(awk -F'\t' '{print $1 "|" $2 "|" $3 "|" $5}' "$D/resources.tsv")"
eq "add again is a no-op" "already recorded: thing t1" "$($S/resource-add.sh "$D" thing t1)"
eq "owner defaults to the thread" "thr_env" "$(T3CODE_THREAD_ID=thr_env $S/resource-add.sh "$D" blind b1 >/dev/null; awk -F'\t' '$2=="b1" {print $3}' "$D/resources.tsv")"
ok "done" $S/resource-done.sh "$D" blind b1
fails 1 "done twice refused" $S/resource-done.sh "$D" blind b1
ok "add after done opens a new row" $S/resource-add.sh "$D" blind b1
eq "two b1 rows" 2 "$(grep -c "	b1	" "$D/resources.tsv")"

# sweep <task-dir>
printf 't1\nt9\n' > "$L"; $S/resource-add.sh "$D" thing gone >/dev/null; $S/resource-add.sh "$D" careful c1 >/dev/null
OUT=$($S/sweep.sh "$D"); rc=$?
eq "sweep exit" 0 "$rc"
ok "alive one stopped" grep -qx 'thing t1: stopped' <<< "$OUT"
ok "gone one marked" grep -qx 'thing gone: already gone' <<< "$OUT"
ok "unlistable one is stopped" grep -qx 'blind b1: stopped' <<< "$OUT"
ok "confirm class kept" grep -qx 'careful c1: kept, needs --confirmed' <<< "$OUT"
eq "only t1 left the list" "t9" "$(cat "$L")"
eq "open rows left" "careful c1" "$(awk -F'\t' '$5=="-" {print $1, $2}' "$D/resources.tsv")"
ok "confirmed stops it" grep -qx 'careful c1: stopped' <<< "$($S/sweep.sh "$D" --confirmed)"
eq "nothing open" "nothing open" "$($S/sweep.sh "$D")"
fails 2 "sweep needs a task" $S/sweep.sh "$FIX/nowhere"

# A failing stop is reported and fails the sweep.
printf 'thing\tcat "$L"\t2\tcat "$L"\tfalse\tauto\n' > "$FIX/.private/config/resources.tsv"
echo t2 > "$L"; $S/resource-add.sh "$D" thing t2 >/dev/null
fails 1 "failed stop fails" $S/sweep.sh "$D"
ok "still open" grep -q $'^thing\tt2\t.*\t-$' "$D/resources.tsv"
rm "$FIX/.private/config/resources.tsv"; $S/sweep.sh "$D" >/dev/null

# --orphans: alive and not owned by an open task, minus what a service protects; never stops anything.
printf 'o1\no2\no3\n' > "$L"; $S/resource-add.sh "$D" thing o1 thr_1 >/dev/null
OUT=$($S/sweep.sh --orphans)
eq "orphans" "$(printf 'thing\to2\nthing\to3\ncareful\tc1')" "$OUT"
eq "nothing stopped" "$(printf 'o1\no2\no3')" "$(cat "$L")"
printf '#!/bin/sh\ncase "$2" in paths) echo "o3,zz*";; threads) echo thr_9;; esac\n' > "$FIX/svc"; chmod +x "$FIX/svc"
eq "protected skipped" "$(printf 'thing\to2\ncareful\tc1')" "$(COORD_SERVICE_SH=$FIX/svc $S/sweep.sh --orphans)"
$S/task-set.sh "$D" status done >/dev/null 2>&1 || sed -i.b 's/^status: .*/status: done/' "$D/task.md"
ok "a closed task owns nothing" grep -qx $'thing\to1' <<< "$($S/sweep.sh --orphans)"
J=$($S/sweep.sh --orphans --json)
ok "json" python3 -c 'import json,sys; d={r["kind"]:r for r in json.loads(sys.argv[1])}; assert d["thing"]=={"kind":"thing","count":"3","limit":"2","state":"HIGH","orphans":["o1","o2","o3"]}; assert d["blind"]["orphans"]==[]' "$J"
: > "$L"; eq "none" "$(printf 'careful\tc1')" "$($S/sweep.sh --orphans)"

# Protected by owner thread in a task sweep.
D2=$($S/task-new.sh personal - res2 "Res2"); echo p1 > "$L"; $S/resource-add.sh "$D2" thing p1 thr_9 >/dev/null
ok "protected owner kept" grep -qx 'thing p1: kept, protected by a service' <<< "$(COORD_SERVICE_SH=$FIX/svc $S/sweep.sh "$D2")"
$S/sweep.sh "$D2" >/dev/null

# The pid-file kind: counted, swept and stopped through the repository script.
P=$(sh -c 'sleep 60 >/dev/null 2>&1 & echo $!'); echo $P > "$COORD_DATA/widget.pid"
eq "pid kind counted" 1 "$($S/sweep.sh --run widget count)"
$S/resource-add.sh "$D2" widget $P >/dev/null
ok "pid kind stopped by its script" grep -qx "widget $P: stopped" <<< "$($S/sweep.sh "$D2")"
sleep 0.2; fails 1 "process gone" kill -0 $P
eq "pid kind reads 0" 0 "$($S/sweep.sh --run widget count)"
kill $P 2>/dev/null

# --worktrees lists recorded worktrees that still exist.
mkdir -p "$FIX/wt-a"; $S/agent-add.sh "$D2" worker claude m medium "$PE/app" "$FIX/wt-a" b thr_w >/dev/null 2>&1 \
  || printf 'worker\tclaude\tm\tmedium\t%s\t%s\tb\tthr_w\t-\n' "$PE/app" "$FIX/wt-a" >> "$D2/agents.tsv"
printf 'worker\tclaude\tm\tmedium\tx\t%s\tb\tthr_x\t-\n' "$FIX/wt-gone" >> "$D2/agents.tsv"
eq "worktrees" "$FIX/wt-a" "$($S/sweep.sh --worktrees)"

# agent-runs: ids 0 and 1 (and anything not a whole number above 1) are never listed nor signalled.
cp "$ROOT/config/resources.tsv" "$FIX/config/resources.tsv"; cp "$ROOT/scripts/live.sh" "$ROOT/scripts/lib.sh" "$FIX/scripts/"
# A worktree recorded as made but not yet on an agent row is alive too, so a sweep keeps its record open.
mkdir -p "$FIX/wt-made"; $S/resource-add.sh "$D2" worktrees "$FIX/wt-made" >/dev/null
eq "a recorded worktree is listed" "$FIX/wt-a $FIX/wt-made" "$($S/sweep.sh --worktrees | tr '\n' ' ' | sed 's/ $//')"
ok "the sweep keeps its record" grep -qx "worktrees $FIX/wt-made: kept, no stop command" <<< "$($S/sweep.sh "$D2" --confirmed)"
ok "still open" grep -q "^worktrees	$FIX/wt-made	.*	-\$" "$D2/resources.tsv"
A=$($S/task-new.sh personal - runs "Runs")
mkdir -p "$A/runs"; printf '1\tsomething\n0\tsomething\n' > "$A/runs/01-worker.start"
eq "pid:1 reads ended" ended "$($S/live.sh pid:1)"
eq "pid:0 reads ended" ended "$($S/live.sh pid:0)"
eq "pid:01 reads ended" ended "$($S/live.sh pid:01)"
for id in 1 0 01 -1; do $S/resource-add.sh "$A" agent-runs "$id" >/dev/null; done
eq "none listed" "" "$($S/sweep.sh --run agent-runs list)"
# Only once nothing above lists them is a stop attempted; it must refuse before any signal.
if [ -z "$($S/sweep.sh --run agent-runs list)" ] && [ "$($S/live.sh pid:1)" = ended ]; then
  fails 1 "stop of pid:1 refused" $S/live.sh --stop pid:1
  fails 1 "stop of pid:0 refused" $S/live.sh --stop pid:0
  out=$($S/sweep.sh "$A")
  eq "the sweep only marks them gone" 4 "$(grep -c ': already gone$' <<< "$out")"
fi
fails 2 "stop needs a process id" $S/live.sh --stop thr_1
ok "ids are compared as text: 1 and 01 are two records" sh -c '[ "$(cut -f2 "$1/resources.tsv" | grep -c "^0*1$")" = 2 ]' _ "$A"

# A table command cut short, or whose sweep is killed, leaves no process; a containers row has its own short limit.
gone() { local i=0; while pgrep -f "$1" >/dev/null; do [ $i -lt 30 ] || return 1; sleep 0.1; i=$((i+1)); done; }
printf '#!/bin/sh\nsleep "$1" &\nsleep "$2"\n' > "$FIX/scripts/hang.sh"; chmod +x "$FIX/scripts/hang.sh"
printf 'hung\t"$ROOT"/scripts/hang.sh 4501 4502\t1\t-\t-\tauto\ncontainers\t"$ROOT"/scripts/hang.sh 4503 4504\t1\t-\t-\tauto\n' > "$FIX/config/resources.tsv"
printf 'RES_TIMEOUT_SEC=1\nCONTAINER_TIMEOUT_SEC=1\n' >> "$FIX/config/health.conf"
eq "a hanging count reads unknown" "hung	unknown	1	unknown" "$($S/sweep.sh --readings | head -1)"
ok "the hanging command is gone after the limit" gone 'sleep 4502'
ok "its child is gone after the limit" gone 'sleep 4501'
printf 'RES_TIMEOUT_SEC=60\nCONTAINER_TIMEOUT_SEC=1\n' >> "$FIX/config/health.conf"
s0=$(date +%s)
eq "the containers row uses the container limit" "containers	unknown	1	unknown" "$($S/sweep.sh --run containers count | sed 's/^/containers	/; s/$/	1	unknown/')"
ok "within the short limit" test $(( $(date +%s) - s0 )) -lt 8
$S/sweep.sh --readings >/dev/null 2>&1 & sp=$!
i=0; until pgrep -f 'sleep 4501' >/dev/null || [ $i -ge 30 ]; do sleep 0.1; i=$((i+1)); done
kill -TERM "$sp"; wait "$sp" 2>/dev/null
ok "sweep killed: the command is gone" gone 'sleep 4502'
ok "sweep killed: its child is gone" gone 'sleep 4501'
