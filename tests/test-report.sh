. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; . "$S/lib.sh"; T=$_TMPROOT/t; mkdir -p "$T/tools"
COORD_TOOLS=$T/tools; COORD_T3=; export COORD_TOOLS COORD_T3
eq "empty inbox" "nothing new" "$($S/report.sh)"
D=$($S/task-new.sh company ABC-123 api "API")
$S/agent-add.sh "$D" sub-coordinator claude m medium "$FIX" - - thr_sub
$S/agent-add.sh "$D" worker claude m medium "$CO/team/service" - - thr_w thr_sub
cat > "$T/h1" <<'H'
## Needs the developer

Gate one: pick "A" or "B" for the $schema \ field.
	- tabbed detail

## Contract written

The contract is written.
H
$S/handoff-write.sh "$D" sub-coordinator coordinator < "$T/h1" >/dev/null
printf '\n\nWorker finished: tests green.\nmore\n' | $S/handoff-write.sh "$D" worker coordinator >/dev/null
printf 'to the sub\n' | $S/handoff-write.sh "$D" worker sub-coordinator >/dev/null

out=$($S/report.sh --peek)
eq "peek shows both" 2 "$(printf '%s\n' "$out" | grep -c '^ABC-123 · ')"
eq "peek marks nothing" 2 "$(grep -c $'\t0$' "$COORD_DATA/inbox.tsv")"
eq "peek changes no state" running "$(awk -F'\t' '$8=="thr_sub" {print $11}' "$D/agents.tsv")"

out=$($S/report.sh)
sed -n '1,4p' "$T/h1" > "$T/want"
{ echo "ABC-123 · sub-coordinator: Contract written"; cat "$T/want"
  echo "ABC-123 · worker: Worker finished: tests green."; } > "$T/want-all"
eq "each line once, the section word for word" "$(cat "$T/want-all")" "$out"
eq "all seen" 0 "$(grep -c $'\t0$' "$COORD_DATA/inbox.tsv")"
eq "sub-coordinator done" done "$(awk -F'\t' '$8=="thr_sub" {print $11}' "$D/agents.tsv")"
eq "worker untouched" running "$(awk -F'\t' '$8=="thr_w" {print $11}' "$D/agents.tsv")"
eq "needs the developer" yes "$(field "$D/task.md" needs_developer)"
ok "board rebuilt with the task under needs you" sh -c "sed -n '/^## Needs you/,/^## Running/p' '$COORD_DATA/board.md' | grep -q '^- ABC-123'"
eq "nothing new after" "nothing new" "$($S/report.sh)"
eq "no temporary left" "" "$(ls -a "$COORD_DATA" | grep -e '^\.report\.' -e '^\.inbox\.')"

# A sub-coordinator handoff without the section leaves needs_developer alone.
$S/task-set.sh "$D" needs_developer no
printf 'Round two done.\n' | $S/handoff-write.sh "$D" sub-coordinator coordinator >/dev/null
eq "plain handoff" "ABC-123 · sub-coordinator: Round two done." "$($S/report.sh)"
eq "needs_developer kept" no "$(field "$D/task.md" needs_developer)"

# A line whose handoff is gone is shown once and marked.
printf '2026-01-01T00:00:00+00:00\ttasks/company/gone\t01-x-to-coordinator.md\tx\t0\n' >> "$COORD_DATA/inbox.tsv"
eq "missing handoff named" "tasks/company/gone · x: (handoff not found: 01-x-to-coordinator.md)" "$($S/report.sh)"
eq "then nothing new" "nothing new" "$($S/report.sh)"
fails 2 "bad option" $S/report.sh --all

# status.sh: what finished, then the board.
printf 'Status check.\n' | $S/handoff-write.sh "$D" worker coordinator >/dev/null
out=$($S/status.sh)
eq "status starts with the report" "ABC-123 · worker: Status check." "$(printf '%s\n' "$out" | head -1)"
ok "status prints the board" sh -c "printf '%s\n' \"\$1\" | grep -q '^# Board '" _ "$out"
eq "status marked it seen" "nothing new" "$($S/report.sh)"
printf '#!/bin/bash\necho "{\\"thread\\":{\\"status\\":\\"running\\"}}"\n' > "$T/t3"; chmod +x "$T/t3"
COORD_T3=$T/t3 $S/status.sh --live > "$T/live"
ok "status --live asks the runtime" grep -q 'thr_w.*\|(live: running)' "$T/live"
ok "live state on the board" grep -q '(live: running)' "$T/live"
fails 2 "status bad option" $S/status.sh --nope

# A fast worker (a worker the coordinator launched, parent -) is done when its handoff arrives.
F=$($S/task-new.sh personal - quick "Quick")
$S/agent-add.sh "$F" worker claude m low "$FIX" - - thr_fast
printf 'Pushed.\n' | $S/handoff-write.sh "$F" worker coordinator >/dev/null
eq "fast worker reported" "quick · worker: Pushed." "$($S/report.sh)"
eq "fast worker done" done "$(awk -F'\t' '$8=="thr_fast" {print $11}' "$F/agents.tsv")"
eq "needs_developer untouched by a worker" no "$(field "$F/task.md" needs_developer)"

# report.sh never removes an inbox lock it does not hold, even from its exit trap.
LOCKD=$COORD_DATA/.inbox.lock
printf 'One more.\n' | $S/handoff-write.sh "$F" worker coordinator >/dev/null
bash -c '. "$1"; lock_take "$2"; sleep 30' _ "$S/lib.sh" "$LOCKD" & HP=$!
i=0; until [ -s "$LOCKD/owner" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i+1)); done
fails 1 "report waits for the lock, then gives up" env LOCK_WAIT_SEC=1 $S/report.sh
ok "the other writer's lock is kept" test -d "$LOCKD"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; rm -rf "$LOCKD"
eq "then it reports" "quick · worker: One more." "$($S/report.sh)"
for i in 1 2 3 4 5 6; do printf 'p%s\n' "$i" | $S/handoff-write.sh "$F" worker coordinator >/dev/null & $S/report.sh >/dev/null & done; wait
$S/report.sh >/dev/null
eq "no inbox line lost beside parallel reports" 6 "$(awk -F'\t' -v d="tasks/personal/quick" '$2==d && $5=="1"' "$COORD_DATA/inbox.tsv" | wc -l | awk '{print $1 - 2}')"
eq "no lock left" "" "$(ls -a "$COORD_DATA" | grep '\.lock$')"
