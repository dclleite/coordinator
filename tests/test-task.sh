. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; . "$S/lib.sh"
D=$($S/task-new.sh company ACME-12345 short-link "Short link API")
eq "path" "$COORD_DATA/tasks/company/ACME-12345-short-link" "$D"
ok "request.md exists" test -f "$D/request.md"
eq "stage" "stage: intake" "$(grep '^stage:' "$D/task.md")"
fails 1 "duplicate refused" $S/task-new.sh company ACME-12345 short-link "x"
fails 2 "bad slug" $S/task-new.sh company ACME-1 "a b" "x"
fails 2 "unknown scope" $S/task-new.sh elsewhere - x "x"
fails 2 "dot-dot slug" $S/task-new.sh personal - "../x" "x"
P=$($S/task-new.sh personal - blog "Blog")
eq "personal path" "$COORD_DATA/tasks/personal/blog" "$P"
$S/task-set.sh "$D" stage build
eq "stage set" "stage: build" "$(grep '^stage:' "$D/task.md")"
$S/task-set.sh "$D" waiting_on 'review of a\tb & c|d'
eq "value kept literally" 'waiting_on: review of a\tb & c|d' "$(grep '^waiting_on:' "$D/task.md")"
fails 2 "unknown field" $S/task-set.sh "$D" colour red
fails 2 "unknown stage" $S/task-set.sh "$D" stage party
$S/task-set.sh "$P" stage done
eq "stage done closes the task" "status: closed|stage: done" "$(grep -e '^stage:' -e '^status:' "$P/task.md" | paste -sd'|' -)"
Q=$($S/task-new.sh personal - dropped "Dropped"); $S/task-set.sh "$Q" status closed
eq "a closed task keeps another stage" "status: closed|stage: intake" "$(grep -e '^stage:' -e '^status:' "$Q/task.md" | paste -sd'|' -)"
$S/agent-add.sh "$D" worker claude claude-opus-5-5 medium $CO/team/service /wt/a acme-1 thr_1
eq "agent row has 11 columns" 11 "$(awk -F'\t' '{print NF}' "$D/agents.tsv")"
eq "parent and state defaults" "-	running" "$(cut -f10,11 "$D/agents.tsv")"
fails 1 "codex on company refused" $S/agent-add.sh "$D" worker codex gpt-6.1-sol medium $CO/team/service /wt/b b thr_2
eq "one agent only" 1 "$(wc -l < "$D/agents.tsv" | tr -d ' ')"
COORD_NOW=2026-11-10T14:03:00-03:00 $S/ledger.sh "$D" escalation "opus high: flaky	test"
eq "ledger line" "2026-11-10T14:03:00-03:00	escalation	opus high: flaky test" "$(tail -1 "$D/ledger.md")"
fails 2 "event outside the list refused" $S/ledger.sh "$D" escalated "x"
for e in launch steer escalation decision gate handoff finding hold panel cleanup note; do ok "event $e" $S/ledger.sh "$D" "$e" "x"; done
eq "new fields empty" "repositories: merge_requests:" "$(grep -e '^repositories:' -e '^merge_requests:' "$D/task.md" | tr '\n' ' ' | sed 's/ $//')"
$S/task-set.sh "$D" repositories "<company-repo>, docs"; $S/task-set.sh "$D" merge_requests "!12 (draft)"
eq "repositories set" "<company-repo>, docs" "$(field "$D/task.md" repositories)"
eq "merge_requests set" "!12 (draft)" "$(field "$D/task.md" merge_requests)"
$S/task-set.sh "$D" complexity trivial
eq "complexity trivial" trivial "$(field "$D/task.md" complexity)"
fails 2 "complexity outside the list" $S/task-set.sh "$D" complexity huge
eq "no temporary left by task-set" "" "$(ls -a "$D" | grep '^\.task')"
fails 2 "empty argument refused" $S/agent-add.sh "$D" worker claude m medium "" /wt/c c thr_3
fails 1 "codex with a company worktree refused" $S/agent-add.sh "$D" worker codex m medium $PE/app $CO/team/service b thr_4
eq "still one agent" 1 "$(wc -l < "$D/agents.tsv" | tr -d ' ')"
$S/agent-add.sh "$D" worker claude m medium $CO/team/web - - thr_5
$S/agent-set.sh "$D" thr_5 worktree $CO/team/web/.claude/worktrees/x
$S/agent-set.sh "$D" thr_5 mr_sha abc123
eq "agent row updated" "$CO/team/web/.claude/worktrees/x	-	thr_5	abc123" "$(awk -F'\t' '$8=="thr_5" {print $6"\t"$7"\t"$8"\t"$9}' "$D/agents.tsv")"
eq "other row untouched" "/wt/a" "$(awk -F'\t' '$8=="thr_1" {print $6}' "$D/agents.tsv")"
fails 1 "unknown thread" $S/agent-set.sh "$D" thr_nope branch x
fails 2 "unknown column" $S/agent-set.sh "$D" thr_5 role boss
$S/agent-add.sh "$D" worker claude m medium $CO/team/service - - thr_6 thr_5
eq "parent recorded" "thr_5	running" "$(awk -F'\t' '$8=="thr_6" {print $10"\t"$11}' "$D/agents.tsv")"
$S/agent-set.sh "$D" thr_6 state done
eq "state set" done "$(awk -F'\t' '$8=="thr_6" {print $11}' "$D/agents.tsv")"
fails 2 "unknown state refused" $S/agent-set.sh "$D" thr_6 state idle
$S/agent-set.sh "$D" thr_6 parent -
eq "parent set" "-" "$(awk -F'\t' '$8=="thr_6" {print $10}' "$D/agents.tsv")"
fails 2 "eleven arguments refused" $S/agent-add.sh "$D" worker claude m medium $CO/team/service - - thr_7 p extra
fails 1 "codex refused for a company task in a personal repo" $S/agent-add.sh "$D" worker codex m medium $PE/app - - thr_8
# Rows written before parent and state still read, and get the defaults when rewritten.
printf 'worker\tclaude\tm\tmedium\t%s\t-\t-\tthr_old\t-\n' "$CO/team/service" >> "$D/agents.tsv"
. "$S/lib.sh"; agent_row "$(grep thr_old "$D/agents.tsv")"
eq "old row reads with defaults" "thr_old - unknown" "$F8 $F10 $F11"
agent_row "$(grep thr_6 "$D/agents.tsv")"
eq "new row reads as written" "thr_6 - done" "$F8 $F10 $F11"
$S/agent-set.sh "$D" thr_old state stopped
eq "old row rewritten with eleven columns" "11	-	stopped" "$(awk -F'\t' '$8=="thr_old" {print NF"\t"$10"\t"$11}' "$D/agents.tsv")"

# Concurrent writers: every update lands.
C=$($S/task-new.sh personal - race "Race")
for i in $(seq 1 12); do $S/agent-add.sh "$C" worker codex m e "$PE/app" - - "thr_$i" >/dev/null; done
for i in $(seq 1 12); do $S/agent-set.sh "$C" "thr_$i" branch "b$i" & done; wait
eq "12 parallel branch updates all land" 12 "$(awk -F'\t' '$7 ~ /^b[0-9]+$/' "$C/agents.tsv" | wc -l | tr -d ' ')"
for i in $(seq 1 12); do $S/agent-set.sh "$C" "thr_$i" state done & $S/agent-add.sh "$C" worker codex m e "$PE/app" - - "thr_n$i" >/dev/null & done; wait
eq "12 state updates beside 12 appends" "12 12" "$(awk -F'\t' '$11=="done" {d++} $8 ~ /^thr_n/ {n++} END {print d+0, n+0}' "$C/agents.tsv")"
$S/task-set.sh "$C" waiting_on a & $S/task-set.sh "$C" stage build & $S/task-set.sh "$C" complexity simple &
$S/task-set.sh "$C" repositories "$PE/app" & $S/task-set.sh "$C" merge_requests "!1" & wait
eq "5 parallel fields all set" "a build simple $PE/app !1" \
  "$(for f in waiting_on stage complexity repositories merge_requests; do printf '%s ' "$(field "$C/task.md" $f)"; done | sed 's/ $//')"
eq "no lock left" "" "$(ls -a "$C" | grep '\.lock$')"
