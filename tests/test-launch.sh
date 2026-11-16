. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; T=$_TMPROOT/t; mkdir -p "$T/tools"
# The coordinator root sits in a folder whose name has spaces and both kinds of quote.
W="$_TMPROOT/my \"co\" ord's"; mv "$FIX" "$W"; FIX=$W; COORD_ROOT=$FIX; COORD_DATA=$FIX/.private
export COORD_ROOT COORD_DATA; cp -R "$ROOT/roles" "$FIX/"
printf '#!/bin/bash\necho "disk_free_gb=40 min=15 ok"\necho healthy\n' > "$T/tools/health.sh"
chmod +x "$T/tools/health.sh"; COORD_TOOLS=$T/tools; COORD_T3=; export COORD_TOOLS COORD_T3
. "$S/lib.sh"
val() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# Fake agents: each reads its brief on stdin and writes one line; the slow one then waits to be stopped.
cat > "$T/agent" <<'A'
#!/bin/bash
printf 'role=[%s] thread=[%s] session=[%s] pwd=%s args=%s first=%s\n' "${COORD_ROLE-unset}" \
  "${T3CODE_THREAD_ID-unset}" "${CLAUDE_CODE_SESSION_ID-unset}" "$(pwd -P)" "$*" "$(head -1)"
A
{ cat "$T/agent"; echo 'sleep 60'; } > "$T/slow"
chmod +x "$T/agent" "$T/slow"
{ printf 'fake\tpersonal\t-\t-\t-\tcd {dir} && %s --model {model} --effort {effort} < {brief}\n' "$T/agent"
  printf 'slow\tpersonal\t-\t-\t-\tcd {dir} && %s -m {model} < {brief}\n' "$T/slow"
  printf 'bare\tpersonal\t-\t-\t-\t-\n'; } > "$COORD_DATA/config/providers.tsv"
printf '*\tfake\tpersonal\n' > "$COORD_DATA/config/routing.tsv"
printf 'fake\tdefault\tm-1\tlow\nslow\tdefault\tm-2\tlow\nbare\tdefault\tm-3\tlow\n' > "$COORD_DATA/config/models.tsv"

# wait_for <seconds> <cmd...>: polls until the command succeeds.
wait_for() { local n=$(( $1 * 10 )); shift; while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n-1)); done; return 1; }

out=$(printf 'write the post\n' | $S/dispatch.sh new personal - post 'Post "it"' --fast)
D=$(val task_dir "$out"); B=$(val brief "$out")
out=$(COORD_ROLE=coordinator T3CODE_THREAD_ID=thr_coord CLAUDE_CODE_SESSION_ID=ses_coord $S/dispatch.sh launch "$D"); rc=$?
eq "launch exit" 0 "$rc"
th=$(val thread "$out"); pid=${th#pid:}; LOG=$(val log "$out")
case "$th" in pid:[0-9]*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)); echo "FAIL: thread is pid:<n> ($th)" ;; esac
eq "log path" "$D/runs/01-worker.log" "$LOG"
ok "agent wrote its line" wait_for 10 grep -q '^role=' "$LOG"
ok "agent ended" wait_for 10 sh -c "[ \"\$($S/live.sh $th)\" = ended ]"
eq "agent output, without the launcher's role, thread and session" "role=[unset] thread=[unset] session=[unset] pwd=$(cd "$FIX" && pwd -P) args=--model m-1 --effort low first=$(head -1 "$B")" "$(cat "$LOG")"
eq "agent row" "worker	fake	m-1	low	$FIX	$th	-	running" "$(cut -f1-5,8,10,11 "$D/agents.tsv")"
ok "launch in the ledger" grep -q $'\tlaunch\tworker fake m-1 low in .* thread '"$th"': 01-fast-worker.md$' "$D/ledger.md"
eq "resource row" "agent-runs	$pid	$th	-" "$(cut -f1-3,5 "$D/resources.tsv")"
ok "nothing left prepared" test ! -f "$D/.dispatch"
fails 1 "launch twice refused" $S/dispatch.sh launch "$D"

# live.sh on a process id.
eq "ended process" ended "$($S/live.sh "$th")"
fails 2 "not a process id" $S/live.sh pid:x
sleep 60 & sp=$!
eq "own process, not a group leader, reads ended" ended "$($S/live.sh "pid:$sp")"
kill "$sp"; wait "$sp" 2>/dev/null

# A running agent: live, counted by health and stopped by the task sweep.
out=$(printf 'slow one\n' | $S/dispatch.sh new personal - slow "Slow" --fast)
D2=$(val task_dir "$out")
sed -i.bak 's/^provider=fake$/provider=slow/; s/^model=m-1$/model=m-2/' "$D2/.dispatch"; rm -f "$D2/.dispatch.bak"
out=$($S/dispatch.sh launch "$D2"); th2=$(val thread "$out"); pid2=${th2#pid:}
ok "slow agent started" wait_for 10 grep -q '^role=' "$D2/runs/01-worker.log"
eq "running" running "$($S/live.sh "$th2")"
eq "listed" "$pid2" "$($S/sweep.sh --run agent-runs list)"
eq "counted" 1 "$($S/sweep.sh --run agent-runs count)"
ok "a health reading" grep -q '^resource.agent-runs' <<< "$($S/health.sh)"
eq "not an orphan" "" "$($S/sweep.sh --orphans | grep agent-runs)"
ok "the start time is saved next to the log" grep -q "^$pid2	." "$D2/runs/01-worker.start"

# A reused process id is not the agent: it reads ended, is not listed, and is never signalled.
cp "$D2/runs/01-worker.start" "$T/start"
printf '%s\tMon Jan  1 00:00:00 2001\n' "$pid2" > "$D2/runs/01-worker.start"
eq "another start time: ended" ended "$($S/live.sh "$th2")"
eq "another start time: not listed" "" "$($S/sweep.sh --run agent-runs list)"
fails 1 "another start time: not stopped" $S/live.sh --stop "$th2"
eq "another start time: the sweep leaves it" "agent-runs $pid2: already gone" "$($S/sweep.sh "$D2")"
ok "still alive" kill -0 -- "-$pid2"
$S/resource-add.sh "$D2" agent-runs "$pid2" "$th2" >/dev/null
rm "$D2/runs/01-worker.start"
eq "nothing saved: ended" ended "$($S/live.sh "$th2")"
eq "marked by hand" "marked: $th2" "$($S/live.sh --mark "$D2" "$th2")"
eq "marked by hand: running" running "$($S/live.sh "$th2")"
other=$($S/task-new.sh personal - other-mark "Other mark")
fails 1 "mark refuses an id another task recorded" $S/live.sh --mark "$other" "$th2"
ok "the other task is named" grep -q 'already recorded by personal/slow' <<< "$($S/live.sh --mark "$other" "$th2" 2>&1)"
rm "$D2/runs/pid-$pid2.start"
fails 2 "mark refuses pid:1" $S/live.sh --mark "$D2" pid:1
# Only a process of this user, started moments ago, can be marked: a stray id from a log is refused.
sleep 30 & old=$!; sleep 2
fails 1 "mark refuses a process started too long ago" env MARK_MAX_AGE_SEC=1 $S/live.sh --mark "$D2" pid:$old
ok "the reason is the age" grep -q "started 2s ago\|started [3-9]s ago" <<< "$(MARK_MAX_AGE_SEC=1 $S/live.sh --mark "$D2" pid:$old 2>&1)"
kill "$old" 2>/dev/null; wait "$old" 2>/dev/null
if [ "$(id -u)" != 0 ]; then
  rp=$(ps -A -o uid=,pid= | awk '$1==0 && $2>1 {print $2; exit}')
  [ -z "$rp" ] || fails 1 "mark refuses another user's process" env MARK_MAX_AGE_SEC=999999999 $S/live.sh --mark "$D2" pid:$rp
fi
ok "nothing saved for a refused mark" sh -c "! ls \"\$1\" | grep -q ^pid-" _ "$D2/runs"
cp "$T/start" "$D2/runs/01-worker.start"
eq "sweep stops it" "agent-runs $pid2: stopped" "$($S/sweep.sh "$D2")"
ok "process group gone" wait_for 10 sh -c "! kill -0 -- -$pid2 2>/dev/null"
eq "ended after the sweep" ended "$($S/live.sh "$th2")"
eq "nothing open" "nothing open" "$($S/sweep.sh "$D2")"

# A message for a task whose sub-coordinator is a process: the ended one is replaced.
out=$(printf 'plan it\n' | $S/dispatch.sh new personal - plan "Plan")
D3=$(val task_dir "$out")
th3=$(val thread "$($S/dispatch.sh launch "$D3")")
wait_for 10 sh -c "[ \"\$($S/live.sh $th3)\" = ended ]"
out=$(printf 'and more\n' | $S/dispatch.sh add "$D3")
eq "send_to the process" "$th3" "$(val send_to "$out")"
th4=$(val thread "$($S/dispatch.sh launch "$D3")")
ok "a new process" test -n "${th4#pid:}" -a "$th4" != "$th3"
eq "old row stopped, new one running" "$th3 stopped|$th4 running|" "$(awk -F'\t' '{printf "%s %s|", $8, $11}' "$D3/agents.tsv")"
eq "two launches in the ledger" 2 "$(grep -c $'\tlaunch\t' "$D3/ledger.md")"
wait_for 10 sh -c "[ \"\$($S/live.sh $th4)\" = ended ]"
out=$(printf 'x\n' | $S/dispatch.sh add "$D3")
sed -i.bak 's/^send_to=.*/send_to=thr_t3/' "$D3/.dispatch"; rm -f "$D3/.dispatch.bak"
fails 1 "a runtime thread is sent to, not launched" $S/dispatch.sh launch "$D3"

# A provider with no launch template.
out=$(printf 'x\n' | $S/dispatch.sh new personal - bare "Bare" --fast)
D5=$(val task_dir "$out")
sed -i.bak 's/^provider=fake$/provider=bare/' "$D5/.dispatch"; rm -f "$D5/.dispatch.bak"
fails 2 "no template" $S/dispatch.sh launch "$D5"
eq "one line" 1 "$($S/dispatch.sh launch "$D5" 2>&1 | wc -l | tr -d ' ')"
ok "nothing recorded" test ! -s "$D5/agents.tsv"
ok "still prepared" test -f "$D5/.dispatch"
fails 2 "usage" $S/dispatch.sh launch
fails 2 "not a task" $S/dispatch.sh launch "$T"

# A headless personal-account sub-coordinator that company records now refuse: add stops it and prepares a new one.
out=$(printf 'slow plan\n' | $S/dispatch.sh new personal - slowplan "Slow plan")
D6=$(val task_dir "$out")
sed -i.bak 's/^provider=fake$/provider=slow/; s/^model=m-1$/model=m-2/' "$D6/.dispatch"; rm -f "$D6/.dispatch.bak"
th6=$(val thread "$($S/dispatch.sh launch "$D6")")
eq "the slow sub-coordinator runs" running "$($S/live.sh "$th6")"
printf 'comp\tcompany\t-\t-\t-\tcd {dir} && %s < {brief}\n' "$T/agent" >> "$COORD_DATA/config/providers.tsv"
printf 'comp\tdefault\tm-4\tlow\n' >> "$COORD_DATA/config/models.tsv"
printf 'company\tcompany\npersonal\tpersonal,company\n' > "$COORD_DATA/config/scopes.tsv"
mkdir -p "$_TMPROOT/co"; printf '%s\tcomp\tcompany\n*\tfake\tpersonal\n' "$_TMPROOT/co" > "$COORD_DATA/config/routing.tsv"
$S/task-new.sh company - acme-task "Acme task" >/dev/null
out=$(printf 'more\n' | $S/dispatch.sh add "$D6")
eq "add names it" "$th6" "$(val stop_thread "$out")"
eq "and prepares a launch on a provider that passes" "comp " "$(val provider "$out") $(val send_to "$out")"
ok "the process is stopped" wait_for 10 sh -c "[ \"\$($S/live.sh $th6)\" = ended ]"
th7=$(val thread "$($S/dispatch.sh launch "$D6")")
eq "old row stopped, the new one recorded" "$th6 stopped|$th7 running|" "$(awk -F'\t' '{printf "%s %s|", $8, $11}' "$D6/agents.tsv")"
