. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; T="$_TMPROOT/ho"; mkdir -p "$T"
D=$($S/task-new.sh personal - h "H")
F=$(echo "Done: endpoint added. Evidence: tests/api.log" | $S/handoff-write.sh "$D" service-worker coordinator)
eq "numbered" "$D/handoffs/01-service-worker-to-coordinator.md" "$F"
ok "frontmatter" grep -q '^from: service-worker$' "$F"
printf 'use glpat-%s here\n' abcdefghijklmnopqrstuv > "$T/s"
fails 1 "secret blocks write" $S/handoff-write.sh "$D" a b < "$T/s"
eq "nothing written" 1 "$(ls "$D/handoffs" | wc -l | tr -d ' ')"
eq "kind not value" "line 1: gitlab token" "$($S/secret-scan.sh "$T/s" 2>/dev/null)"
echo 'the token rotation policy is documented' > "$T/c"
ok "plain prose passes" $S/secret-scan.sh "$T/c"
printf 'ok line\npassword = "%s%s"\n' hunter2 hunter2 > "$T/p"
eq "assignment caught on its line" "line 2: credential assignment" "$($S/secret-scan.sh "$T/p" 2>/dev/null)"
fails 2 "bad name" $S/handoff-write.sh "$D" "a/b" c < "$T/c"
rm -rf "$T"
T="$_TMPROOT/ho2"; mkdir -p "$T"
at=@
hit() { printf '%s\n' "$2" > "$T/f"; fails 1 "caught: $1" $S/secret-scan.sh "$T/f"; }
pass() { printf '%s\n' "$2" > "$T/f"; ok "allowed: $1" $S/secret-scan.sh "$T/f"; }
# Each fake credential is joined at run time, so no tracked file holds a whole one.
hit "unquoted env assignment" "$(printf '%s=%s' GITLAB_TOKEN abcd1234efgh5678)"
hit "aws secret" "$(printf '%s=%s' AWS_SECRET_ACCESS_KEY wJalrXUtnFEMIK7MDENGbPxRfiCY)"
hit "fine-grained github token" "github_pat_""11ABCDEFG0abcdefghijkl"
hit "credentials in a url" "clone https://user:s3cretpass${at}code.example.com/x.git"
hit "jwt" "eyJhbGciOiJIUzI1NiJ9"".eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123"
hit "bearer with a real token" "Authorization: Bearer ""abc123def456ghi789jkl012"
pass "quoted prose after token:" 'token: "see vault for value"'
pass "quoted prose after secret =" 'secret = "not stored in the repo"'
pass "bearer in prose" "Bearer authentication-with-refresh-rotation"
pass "branch name with sk-" "task/sk-refactor-the-whole-module-now"
rm -rf "$T"

# A handoff whose inbox line cannot be written leaves nothing, so a retry is clean.
D=$($S/task-new.sh personal - inboxlock "Inbox lock")
bash -c '. "$1"; lock_take "$2"; sleep 30' _ "$S/lib.sh" "$COORD_DATA/.inbox.lock" & HP=$!
i=0; until [ -s "$COORD_DATA/.inbox.lock/owner" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i+1)); done
printf 'done\n' > "$_TMPROOT/body"
fails 1 "inbox busy: refused" env LOCK_WAIT_SEC=1 $S/handoff-write.sh "$D" worker coordinator < "$_TMPROOT/body"
eq "no handoff file without its inbox line" "" "$(ls -A "$D/handoffs" 2>/dev/null)"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
# A lock left by a writer killed outright does not block the next one.
bash -c '. "$1"; lock_take "$2"; exec sleep 30' _ "$S/lib.sh" "$COORD_DATA/.inbox.lock" & HP=$!
i=0; until [ -s "$COORD_DATA/.inbox.lock/owner" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i+1)); done
kill -KILL "$HP"; wait "$HP" 2>/dev/null
eq "the retry takes the first number" "$D/handoffs/01-worker-to-coordinator.md" "$(env LOCK_WAIT_SEC=2 $S/handoff-write.sh "$D" worker coordinator < "$_TMPROOT/body" 2>/dev/null)"
eq "one inbox line" 1 "$(grep -c 'tasks/personal/inboxlock' "$COORD_DATA/inbox.tsv")"

# Twenty writers at the same moment: twenty files, twenty numbers, twenty inbox lines.
rm -rf "$_TMPROOT"; mktask; S="$ROOT/scripts"; T=$_TMPROOT/c; mkdir -p "$T"
D=$($S/task-new.sh personal - many "Many")
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  ( printf 'part %s done\n' "$i" | $S/handoff-write.sh "$D" "worker-$i" coordinator > "$T/out-$i" ) &
done
wait
eq "twenty files" 20 "$(ls "$D/handoffs" | grep -c '^[0-9][0-9]*-.*\.md$')"
eq "twenty numbers" 20 "$(ls "$D/handoffs" | sed -n 's/^\([0-9][0-9]*\)-.*/\1/p' | sort -u | grep -c .)"
eq "numbers 01 to 20" "01 20" "$(ls "$D/handoffs" | sed -n 's/^\([0-9][0-9]*\)-.*/\1/p' | sort -n | sed -n '1p;$p' | tr '\n' ' ' | sed 's/ $//')"
eq "twenty inbox lines" 20 "$(grep -c . "$COORD_DATA/inbox.tsv")"
eq "every inbox line names its file" 20 "$(cut -f3 "$COORD_DATA/inbox.tsv" | sort -u | while read -r f; do [ -f "$D/handoffs/$f" ] && echo "$f"; done | grep -c .)"
eq "every writer printed its own path" 20 "$(cat "$T"/out-* | sort -u | grep -c .)"
eq "body kept" "part 7 done" "$(tail -1 "$(cat "$T/out-7")")"
eq "no temporary left" "" "$(ls -a "$D" "$D/handoffs" | grep -e '^\.handoff\.' -e '^\.writing\.')"
ok "no lock left" test ! -e "$COORD_DATA/.inbox.lock"
line=$(head -1 "$COORD_DATA/inbox.tsv")
eq "inbox columns" "tasks/personal/many	worker-	0" "$(printf '%s' "$line" | cut -f2,4,5 | sed 's/worker-[0-9]*/worker-/')"
echo "x" | $S/handoff-write.sh "$D" a sub-coordinator >/dev/null
eq "no inbox line for another addressee" 20 "$(grep -c . "$COORD_DATA/inbox.tsv")"
