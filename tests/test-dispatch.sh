. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; T=$_TMPROOT/t; mkdir -p "$T/tools"; cp -R "$ROOT/roles" "$FIX/"
printf '#!/bin/bash\necho "disk_free_gb=40 min=15 ok"\necho healthy\n' > "$T/tools/health.sh"
chmod +x "$T/tools/health.sh"; COORD_TOOLS=$T/tools; COORD_T3=; export COORD_TOOLS COORD_T3
. "$S/lib.sh"
val() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# The message: quotes, backslashes, a dollar sign, tabs and no final newline.
printf 'say "hi" \\n it'"'"'s $HOME\tthen\ttab\\\\ end' > "$T/m"
out=$($S/dispatch.sh new personal - blog-post 'Blog "post" it'"'"'s' < "$T/m")
D=$(val task_dir "$out")
eq "task created" "$COORD_DATA/tasks/personal/blog-post" "$D"
{ sed -n 1p "$D/request.md"; cat "$T/m"; printf '\n<!-- /msg 1 -->\n'; } > "$T/want"
ok "message stored byte for byte" cmp "$T/want" "$D/request.md"
ok "missing newline recorded" grep -q '| nl: added -->$' "$D/request.md"
B=$(val brief "$out")
eq "brief path" "$D/briefs/01-sub-coordinator.md" "$B"
ok "brief verifies" $S/brief-check.sh "$D" "$B"
eq "role" sub-coordinator "$(val role "$out")"
eq "provider" codex "$(val provider "$out")"
eq "model from the table" "$(cut -f1 <<< "$($S/model.sh codex default)")" "$(val model "$out")"
eq "title" "blog-post · sub-coordinator · coord" "$(val title "$out")"
eq "launch message" "Your brief is the file $B. Read it whole before anything else, run $FIX/scripts/brief-check.sh $D $B and stop if it fails, then do what it says." "$(val message "$out")"
ok "role placeholders filled" grep -qF "task blog-post: Blog \"post\" it's, which" "$B"
fails 1 "no placeholder left" grep -qF '[task-dir]' "$B"
ok "launch prepared" test -f "$D/.dispatch"
eq "no temporary left" "" "$(ls -a "$D" "$COORD_DATA" | grep -e '^\.dispatch-' -e '^\.request\.')"
eq "no send_to on a launch" "" "$(val send_to "$out")"

$S/dispatch.sh launched "$D" thr_sub1 >/dev/null
eq "agent recorded" "sub-coordinator	codex	$FIX	-	thr_sub1	-	running" "$(cut -f1,2,5,7,8,10,11 "$D/agents.tsv")"
ok "launch in the ledger" grep -q $'\tlaunch\tsub-coordinator codex' "$D/ledger.md"
ok "board rebuilt" grep -q 'thr_sub1\|blog-post' "$COORD_DATA/board.md"
fails 1 "launched twice refused" $S/dispatch.sh launched "$D" thr_sub1

# add: the task has a sub-coordinator, so the message goes to its thread.
out=$(printf 'second message\n' | $S/dispatch.sh add "$D" --question "Which blog?")
eq "send_to the sub-coordinator" thr_sub1 "$(val send_to "$out")"
eq "second brief" "$D/briefs/02-sub-coordinator.md" "$(val brief "$out")"
ok "second brief verifies" $S/brief-check.sh "$D" "$(val brief "$out")"
ok "question stored aside" grep -q '^msg 2: Which blog?$' "$D/questions.md"
$S/agent-set.sh "$D" thr_sub1 state done
$S/dispatch.sh launched "$D" thr_sub1 >/dev/null
eq "send marks it running again" running "$(cut -f11 "$D/agents.tsv")"
eq "still one agent" 1 "$(grep -c . "$D/agents.tsv")"
ok "steer in the ledger" grep -q $'\tsteer\t' "$D/ledger.md"
out=$(printf 'x\n' | $S/dispatch.sh add "$D"); fails 1 "send prepared for one thread only" $S/dispatch.sh launched "$D" thr_other

# --fast prepares a worker, not a sub-coordinator.
out=$(printf 'push the branch\n' | $S/dispatch.sh new personal - push-it "Push it" --fast)
F=$(val task_dir "$out")
eq "fast role" worker "$(val role "$out")"
eq "fast brief name" "$F/briefs/01-fast-worker.md" "$(val brief "$out")"
ok "fast worker context" grep -q '^# Context for a fast worker$' "$(val brief "$out")"
eq "fast is trivial" trivial "$(field "$F/task.md" complexity)"
$S/dispatch.sh launched "$F" thr_fast >/dev/null
eq "fast worker row, parent -" "worker	-	running" "$(cut -f1,10,11 "$F/agents.tsv")"
out=$(printf 'and tag it\n' | $S/dispatch.sh add "$F")
eq "add without a sub-coordinator prepares a launch" "sub-coordinator " "$(val role "$out") $(val send_to "$out")"

# A company task picks the company provider and fills instance and effort option.
printf 'claude\tcompany\tclaudeAgent\teffort\t-\t-\n' > "$COORD_DATA/config/providers.tsv"
printf 'codex\tpersonal\t-\t-\t-\t-\n' >> "$COORD_DATA/config/providers.tsv"
out=$(printf 'fix it\n' | $S/dispatch.sh new company ABC-123 fix "Fix it" --repo "$CO/team/service")
eq "company provider" "claude claudeAgent effort" "$(val provider "$out") $(val instance "$out") $(val effort_option "$out")"
eq "title with key" "ABC-123 · sub-coordinator · coord" "$(val title "$out")"
eq "repositories recorded" "$CO/team/service" "$(field "$(val task_dir "$out")/task.md" repositories)"

# A non-default tier needs a reason, and the reason reaches the ledger.
fails 2 "tier without a reason" sh -c "printf 'x' | $S/dispatch.sh new personal - tier-x 'X' --tier escalated"
ok "nothing made" test ! -e "$COORD_DATA/tasks/personal/tier-x"
printf 'hard concurrency bug\nmore context\n' > "$T/ctx"
out=$(printf 'x\n' | $S/dispatch.sh new personal - tier-y "Y" --tier escalated --context "$T/ctx")
ok "escalation in the ledger" grep -q $'\tescalation\tescalated: hard concurrency bug$' "$(val task_dir "$out")/ledger.md"
ok "context in the brief" grep -q '^more context$' "$(val brief "$out")"

# An unhealthy machine: nothing is created.
printf '#!/bin/bash\necho "disk_free_gb=3 min=15 LOW"\necho "unhealthy: disk"\nexit 1\n' > "$T/tools/health.sh"
fails 1 "unhealthy refuses" sh -c "printf 'x' | $S/dispatch.sh new personal - sick 'Sick'"
eq "reason printed" "health=unhealthy: disk" "$(printf 'x' | $S/dispatch.sh new personal - sick 'Sick' 2>/dev/null)"
ok "no task folder" test ! -e "$COORD_DATA/tasks/personal/sick"
before=$(cat "$D/request.md")
fails 1 "add refused too" sh -c "printf 'x' | $S/dispatch.sh add '$D'"
eq "request untouched" "$before" "$(cat "$D/request.md")"
printf '#!/bin/bash\necho healthy\n' > "$T/tools/health.sh"

# A failure after the task was made leaves nothing behind.
printf 'company\tnone\n' > "$COORD_DATA/config/scopes.tsv"
fails 1 "no provider allowed" sh -c "printf 'x' | $S/dispatch.sh new company - nobody 'N'"
ok "half-made task removed" test ! -e "$COORD_DATA/tasks/company/nobody"
printf 'company\tcompany\npersonal\tpersonal,company,local\n' > "$COORD_DATA/config/scopes.tsv"
fails 2 "empty message" $S/dispatch.sh new personal - empty "E" < /dev/null
fails 2 "unknown option" sh -c "printf x | $S/dispatch.sh new personal - o 'O' --nope"

# tasks: one hit, several hits, none.
lines=$($S/dispatch.sh tasks)
eq "every open task listed" 4 "$(printf '%s\n' "$lines" | grep -c .)"
one=$($S/dispatch.sh tasks 'BLOG "POST"')
eq "one hit, case ignored" "blog-post	Blog \"post\" it's	intake	thr_sub1	$D" "$one"
eq "several hits" "ABC-123 blog-post push-it" "$($S/dispatch.sh tasks IT | cut -f1 | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
eq "match by key" ABC-123 "$($S/dispatch.sh tasks abc-1 | cut -f1)"
eq "no hit" none "$($S/dispatch.sh tasks zebra)"
$S/task-set.sh "$F" status closed
fails 1 "closed task not listed" sh -c "$S/dispatch.sh tasks push | grep -q push-it"

# --repo must lie in the scope the task is created in.
fails 1 "a company repo for a personal task refused" sh -c 'printf "x\n" | "$1"/dispatch.sh new personal - mixup "Mixup" --repo "$2"' _ "$S" "$CO/team/service"
ok "nothing created" test ! -e "$COORD_DATA/tasks/personal/mixup"
ok "the scope is named" grep -q 'company scope, not personal' <<< "$(printf 'x\n' | $S/dispatch.sh new personal - mixup "Mixup" --repo "$CO/team/service" 2>&1)"
out=$(printf 'x\n' | $S/dispatch.sh new company - fine "Fine" --repo "$CO/team/service")
eq "matching scope accepted" claude "$(val provider "$out")"

# A personal-account sub-coordinator in the coordinator's folder is not reused once company records exist.
mktask; cp -R "$ROOT/roles" "$FIX/"
out=$(printf 'p1\n' | $S/dispatch.sh new personal - p1 "P1"); P1=$(val task_dir "$out")
eq "a personal task alone: codex" codex "$(val provider "$out")"
$S/dispatch.sh launched "$P1" thr_codex >/dev/null
out=$(printf 'c1\n' | $S/dispatch.sh new company - c1 "C1" --repo "$CO/team/service"); C1=$(val task_dir "$out")
eq "a new company task names the personal agent to stop" thr_codex "$(val stop_thread "$out")"
ok "its ledger says so" grep -q $'\tdecision\tstop sub-coordinator codex thread thr_codex of p1' "$C1/ledger.md"
out=$(printf 'p1 again\n' | $S/dispatch.sh add "$P1")
eq "add names the old thread to stop" thr_codex "$(val stop_thread "$out")"
eq "nothing is sent to it" "" "$(val send_to "$out")"
eq "a new sub-coordinator with a provider that passes" "sub-coordinator claude" "$(val role "$out") $(val provider "$out")"
ok "its brief verifies" $S/brief-check.sh "$P1" "$(val brief "$out")"
ok "the brief is the full role text" grep -qx '# Context for a sub-coordinator' "$(val brief "$out")"
ok "the brief carries both messages" sh -c 'grep -qx "p1" "$1" && grep -qx "p1 again" "$1"' _ "$(val brief "$out")"
eq "the old row is stopped" stopped "$(awk -F'\t' '$8=="thr_codex" {print $11}' "$P1/agents.tsv")"
ok "the ledger says why" grep -q $'\tdecision\tsub-coordinator codex thread thr_codex' "$P1/ledger.md"
$S/dispatch.sh launched "$P1" thr_claude >/dev/null
eq "the new one is recorded beside it" "codex stopped claude running" "$(cut -f2,11 "$P1/agents.tsv" | tr '\t\n' '  ' | sed 's/ $//')"
out=$(printf 'p1 third\n' | $S/dispatch.sh add "$P1")
eq "the new one is reused" "thr_claude " "$(val send_to "$out") $(val stop_thread "$out")"
out=$(printf 'c2\n' | $S/dispatch.sh new company - c2 "C2" --repo "$CO/team/service")
eq "a stopped agent is not named again" "" "$(val stop_thread "$out")"
