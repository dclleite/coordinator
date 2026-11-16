. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"
$S/board.sh; ok "empty board" grep -q '^No open tasks\.$' "$COORD_DATA/board.md"
A=$($S/task-new.sh company ACME-1 a "Alpha"); B=$($S/task-new.sh company ACME-2 b "Beta")
ok "merge allowed by default" $S/hold.sh may-merge "$A"
$S/hold.sh on "$A"
fails 1 "task hold" $S/hold.sh may-merge "$A"
ok "other task free" $S/hold.sh may-merge "$B"
ok "hold in ledger" grep -q $'\thold\tmerge hold on$' "$A/ledger.md"
$S/hold.sh on --all; ok "global hold in every open ledger" grep -q $'\thold\tglobal merge hold on$' "$B/ledger.md"
$S/hold.sh off "$A"
fails 1 "global hold survives task off" $S/hold.sh may-merge "$A"
$S/hold.sh off --all; ok "lifted" $S/hold.sh may-merge "$A"
$S/task-set.sh "$B" needs_developer yes; $S/task-set.sh "$B" stage developer-review
$S/hold.sh on --all; $S/board.sh
eq "needs-you lists the task" "- ACME-2 · Beta · developer-review" "$(sed -n '/^## Needs you$/,/^## /p' "$COORD_DATA/board.md" | grep '^- ')"
eq "needs-you first among running" "### ACME-2 · Beta" "$(grep '^### ' "$COORD_DATA/board.md" | head -1)"
ok "global hold shown" grep -q '^Global merge hold: ON$' "$COORD_DATA/board.md"
$S/task-set.sh "$A" status closed; $S/board.sh
fails 1 "closed task hidden" grep -q 'ACME-1 ' "$COORD_DATA/board.md"
na=$(grep -c . "$A/ledger.md")
$S/hold.sh off --all; ok "global off in the ledger of open tasks" grep -q $'\thold\tglobal merge hold off$' "$B/ledger.md"
eq "closed task gets no global line" "$na" "$(grep -c . "$A/ledger.md")"
# may-merge fails closed: anything but an exact "no" is a hold.
C=$($S/task-new.sh company ACME-3 c "Gamma"); $S/hold.sh off --all
sed 's/^hold_merge: no$/hold_merge: Yes/' "$C/task.md" > "$C/t" && mv "$C/t" "$C/task.md"
fails 1 "hand-written Yes is a hold" $S/hold.sh may-merge "$C"
grep -v '^hold_merge:' "$C/task.md" > "$C/t" && mv "$C/t" "$C/task.md"
fails 1 "missing field is a hold" $S/hold.sh may-merge "$C"
fails 1 "setting a missing field fails" $S/task-set.sh "$C" hold_merge yes
fails 1 "hold on reports the failure" $S/hold.sh on "$C"
: > "$C/task.md"; fails 1 "empty task.md is a hold" $S/hold.sh may-merge "$C"
