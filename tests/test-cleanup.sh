. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"
# Fixture: one repository and worktrees that are pushed+clean, dirty, and unpushed.
# "Pushed" is simulated with a remote-tracking ref, so the test needs no remote.
X="$_TMPROOT/cl"; mkdir -p "$X/tpl"; export GIT_TEMPLATE_DIR="$X/tpl"
git init -q "$X/repo"; cd "$X/repo"; git commit -q --allow-empty -m init
on_remote() { git -C "$X/repo" update-ref "refs/remotes/origin/$1" "$1"; }
# What the agent that creates a worktree records; only a recorded worktree is ever removed.
made() { $S/resource-add.sh "$1" worktrees "$2" >/dev/null; }
for n in pushed dirty unpushed; do git worktree add -q "$X/repo/.claude/worktrees/wt-$n" -b "$n" 2>/dev/null; done
on_remote pushed; on_remote dirty; echo x > "$X/repo/.claude/worktrees/wt-dirty/new.txt"
git -C "$X/repo/.claude/worktrees/wt-unpushed" commit -q --allow-empty -m local
D=$($S/task-new.sh personal - c "C")
for n in pushed dirty unpushed; do
  $S/agent-add.sh "$D" worker claude m medium "$X/repo" "$X/repo/.claude/worktrees/wt-$n" "$n" "thr_$n"
  made "$D" "$X/repo/.claude/worktrees/wt-$n"
done
OUT=$($S/worktree-cleanup.sh "$D")
eq "summary" "removed=1 queued=0 kept=2" "$(echo "$OUT" | tail -1)"
fails 1 "pushed worktree gone" test -d "$X/repo/.claude/worktrees/wt-pushed"
ok "dirty kept" test -f "$X/repo/.claude/worktrees/wt-dirty/new.txt"
ok "unpushed kept" test -d "$X/repo/.claude/worktrees/wt-unpushed"
ok "reason printed" grep -q "kept $X/repo/.claude/worktrees/wt-dirty: uncommitted changes" <<< "$OUT"
eq "the removed one's record is closed" "" "$(awk -F'\t' '$2 ~ /wt-pushed$/ && $5=="-"' "$D/resources.tsv")"
eq "the kept ones stay open" 2 "$(awk -F'\t' '$1=="worktrees" && $5=="-"' "$D/resources.tsv" | grep -c .)"
# The batch retries a queued worktree that is still safe and keeps the one that is not.
git -C "$X/repo" worktree add -q "$X/repo/.claude/worktrees/wt-queued" -b queued 2>/dev/null; on_remote queued
made "$D" "$X/repo/.claude/worktrees/wt-queued"
printf '%s\t%s\t-\ttasks/personal/c\n' "$X/repo" "$X/repo/.claude/worktrees/wt-queued" > "$COORD_DATA/tasks/cleanup-pending.tsv"
printf '%s\t%s\t-\ttasks/personal/c\n' "$X/repo" "$X/repo/.claude/worktrees/wt-dirty" >> "$COORD_DATA/tasks/cleanup-pending.tsv"
eq "batch summary" "removed=1 queued=0 kept=1" "$($S/cleanup-pending.sh | tail -1)"
eq "kept line stays queued" 1 "$(wc -l < "$COORD_DATA/tasks/cleanup-pending.tsv" | tr -d ' ')"
eq "the batch closes the record of what it removed" "" "$(awk -F'\t' '$2 ~ /wt-queued$/ && $5=="-"' "$D/resources.tsv")"
# The main checkout is never a candidate, and a refused removal is queued once, not on every run.
M=$($S/task-new.sh personal - m "M")
$S/agent-add.sh "$M" worker claude m medium "$X/repo" "$X/repo" main thr_main
eq "main checkout kept" "kept $X/repo: the main checkout" "$($S/worktree-cleanup.sh "$M" | head -1)"
# A queue row with an empty column is kept as malformed, never shifted into the wrong column.
printf '\t%s\t-\n' "$X/repo/.claude/worktrees/wt-dirty" > "$COORD_DATA/tasks/cleanup-pending.tsv"
eq "malformed row kept" "removed=0 queued=0 kept=1" "$($S/cleanup-pending.sh | tail -1)"
ok "dirty worktree untouched" test -f "$X/repo/.claude/worktrees/wt-dirty/new.txt"
eq "malformed row stays" 1 "$(wc -l < "$COORD_DATA/tasks/cleanup-pending.tsv" | tr -d ' ')"
cd /; rm -rf "$X"
# A worktree a service protects is never removed, by either script, and the output says why.
X="$_TMPROOT/cl"; mkdir -p "$X/tpl"; export GIT_TEMPLATE_DIR="$X/tpl"
git init -q "$X/repo"; cd "$X/repo"; git commit -q --allow-empty -m init
for n in svc-prod svc-cache-1 free; do git worktree add -q "$X/repo/.claude/worktrees/wt-$n" -b "$n" 2>/dev/null; on_remote "$n"; done
mkdir -p "$COORD_DATA/services"
printf 'protect=%s,%s\n' "$X/repo/.claude/worktrees/wt-svc-prod" "$X/repo/.claude/worktrees/wt-svc-cache-*" > "$COORD_DATA/services/acme.conf"
P=$($S/task-new.sh personal - p "P")
for n in svc-prod svc-cache-1 free; do
  $S/agent-add.sh "$P" worker claude m medium "$X/repo" "$X/repo/.claude/worktrees/wt-$n" "$n" "thr_$n"
  made "$P" "$X/repo/.claude/worktrees/wt-$n"
done
OUT=$($S/worktree-cleanup.sh "$P")
eq "protected summary" "removed=1 queued=0 kept=2" "$(echo "$OUT" | tail -1)"
ok "exact protected path kept" test -d "$X/repo/.claude/worktrees/wt-svc-prod"
ok "prefix protected path kept" test -d "$X/repo/.claude/worktrees/wt-svc-cache-1"
ok "protection is named" grep -q "kept $X/repo/.claude/worktrees/wt-svc-prod: protected by a service" <<< "$OUT"
fails 1 "unprotected worktree removed" test -d "$X/repo/.claude/worktrees/wt-free"
printf '%s\t%s\t-\n' "$X/repo" "$X/repo/.claude/worktrees/wt-svc-prod" > "$COORD_DATA/tasks/cleanup-pending.tsv"
OUT=$($S/cleanup-pending.sh)
eq "batch keeps protected" "removed=0 queued=0 kept=1" "$(echo "$OUT" | tail -1)"
ok "batch names protection" grep -q "protected by a service" <<< "$OUT"
ok "batch left it on disk" test -d "$X/repo/.claude/worktrees/wt-svc-prod"
cd /; rm -rf "$X"

# A worktree is removed only when no other open task records it and the coordinator could have made it:
# inside the repository's .claude/worktrees/ or a folder listed in DATA/config/worktree-roots.txt.
X="$_TMPROOT/cl"; mkdir -p "$X/tpl"; export GIT_TEMPLATE_DIR="$X/tpl"
git init -q "$X/repo"; cd "$X/repo"; git commit -q --allow-empty -m init
WT=$X/repo/.claude/worktrees
for n in shared closed; do git worktree add -q "$WT/$n" -b "$n" 2>/dev/null; on_remote "$n"; done
git worktree add -q "$X/mine" -b mine 2>/dev/null; on_remote mine
mkdir -p "$X/roots"; git worktree add -q "$X/roots/listed" -b listed 2>/dev/null; on_remote listed
echo "secret" > "$WT/shared/.env"; printf '.env\n' > "$WT/shared/.gitignore"
git -C "$WT/shared" add .gitignore; git -C "$WT/shared" commit -q -m ignore; on_remote shared
A=$($S/task-new.sh personal - a "A"); B=$($S/task-new.sh personal - b "B"); C=$($S/task-new.sh personal - closed "Closed")
for n in shared closed; do $S/agent-add.sh "$A" worker claude m medium "$X/repo" "$WT/$n" "$n" "thr_a$n"; made "$A" "$WT/$n"; done
for n in mine roots/listed; do $S/agent-add.sh "$A" worker claude m medium "$X/repo" "$X/$n" "${n#*/}" "thr_a${n#*/}"; made "$A" "$X/$n"; done
$S/agent-add.sh "$B" worker claude m medium "$X/repo" "$WT/shared/" shared thr_b
$S/agent-add.sh "$C" worker claude m medium "$X/repo" "$WT/closed" closed thr_c
$S/task-set.sh "$C" status closed >/dev/null
printf '# folders this coordinator makes worktrees in\n%s/\n' "$X/roots" > "$COORD_DATA/config/worktree-roots.txt"
OUT=$($S/worktree-cleanup.sh "$A")
ok "shared worktree kept" test -f "$WT/shared/.env"
ok "the other task is named" grep -qF "kept $WT/shared: recorded by another open task: personal/b" <<< "$OUT"
fails 1 "a closed task's record does not keep it" test -d "$WT/closed"
fails 1 "a folder listed in worktree-roots.txt is the coordinator's" test -d "$X/roots/listed"
ok "a folder the developer made is kept" test -d "$X/mine"
eq "summary" "removed=2 queued=0 kept=2" "$(echo "$OUT" | tail -1)"
rm -f "$COORD_DATA/config/worktree-roots.txt"
printf '%s\t%s\t-\ttasks/personal/a\n' "$X/repo" "$X/mine" > "$COORD_DATA/tasks/cleanup-pending.tsv"
printf '%s\t%s\t-\ttasks/personal/a\n' "$X/repo" "$WT/shared" >> "$COORD_DATA/tasks/cleanup-pending.tsv"
OUT=$($S/cleanup-pending.sh)
eq "batch keeps both" "removed=0 queued=0 kept=2" "$(echo "$OUT" | tail -1)"
ok "batch names the location rule" grep -qF "kept $X/mine: not in a worktrees folder of the coordinator" <<< "$OUT"
ok "batch names the other task" grep -qF "kept $WT/shared: recorded by another open task: personal/b" <<< "$OUT"
# A removal git refuses (a locked worktree) is queued with the task that recorded it.
git worktree add -q "$WT/locked" -b locked 2>/dev/null; on_remote locked; git worktree lock "$WT/locked"
L=$($S/task-new.sh personal - locked "Locked"); $S/agent-add.sh "$L" worker claude m medium "$X/repo" "$WT/locked" locked thr_l
made "$L" "$WT/locked"
: > "$COORD_DATA/tasks/cleanup-pending.tsv"
ok "locked worktree queued" grep -q "^queued $WT/locked: " <<< "$($S/worktree-cleanup.sh "$L")"
eq "queue row names its task" "$(printf '%s\t%s\t-\ttasks/personal/locked' "$X/repo" "$WT/locked")" "$(cat "$COORD_DATA/tasks/cleanup-pending.tsv")"
git worktree unlock "$WT/locked"
# A worktree the developer made in the same folder, recorded by a task but never recorded as made: kept, with its files.
git worktree add -q "$WT/devown" -b devown 2>/dev/null
printf '.env\n' > "$WT/devown/.gitignore"; git -C "$WT/devown" add .gitignore; git -C "$WT/devown" commit -q -m ignore
on_remote devown; echo "secret" > "$WT/devown/.env"
V=$($S/task-new.sh personal - devown "Devown"); $S/agent-add.sh "$V" worker claude m medium "$X/repo" "$WT/devown" devown thr_v
OUT=$($S/worktree-cleanup.sh "$V")
ok "an unrecorded worktree keeps its ignored files" test -f "$WT/devown/.env"
ok "the reason names the record" grep -qF "kept $WT/devown: not recorded as made by the coordinator" <<< "$OUT"
printf '%s\t%s\t-\ttasks/personal/devown\n' "$X/repo" "$WT/devown" > "$COORD_DATA/tasks/cleanup-pending.tsv"
ok "the batch keeps it too" grep -qF "kept $WT/devown: not recorded as made by the coordinator" <<< "$($S/cleanup-pending.sh)"
$S/resource-add.sh "$V" worktrees "$WT/devown" >/dev/null; $S/resource-done.sh "$V" worktrees "$WT/devown" >/dev/null
ok "a closed record does not count" grep -qF "kept $WT/devown: not recorded as made" <<< "$($S/worktree-cleanup.sh "$V")"
$S/resource-add.sh "$V" worktrees "$WT/devown/" >/dev/null
$S/worktree-cleanup.sh "$V" >/dev/null
ok "an open record, spelled with a slash: removed" test ! -d "$WT/devown"
# A row queued before the owner column counts every open task as another one.
printf '%s\t%s\t-\n' "$X/repo" "$X/mine" > "$COORD_DATA/tasks/cleanup-pending.tsv"
ok "old row: kept while any open task records it" grep -qF "recorded by another open task: personal/a" <<< "$($S/cleanup-pending.sh)"
cd /; rm -rf "$X"
