. "$(dirname "$0")/lib.sh"
# The fixtures of tests/lib.sh never outlive the test that made them: not a second mktask, not a signal.
H=$(mktemp -d "${TMPDIR%/}/fixtures-test.XXXXXX"); H=$(cd "$H" && pwd -P)
trap 'rm -rf "$H"; _finish' EXIT
child() { TMPDIR=$H bash -c '. "$1"; mktask; echo "$_TMPROOT"; mktask; echo "$_TMPROOT"; '"$1" _ "$ROOT/tests/lib.sh"; }

out=$(child "" | grep -v '^RESULT')
eq "two fixtures made" 2 "$(printf '%s\n' "$out" | grep -c .)"
eq "both removed on exit" "" "$(ls "$H")"

child 'kill -TERM $$; sleep 5' > "$H/out" 2>/dev/null
eq "removed when the test is stopped" "" "$(ls "$H" | grep -v '^out$')"
rm -f "$H/out"

# A test killed outright cannot clean up; the next mktask removes a fixture whose test is gone.
child 'kill -KILL $$' > "$H/out" 2>/dev/null
eq "a killed test leaves its fixture" 2 "$(ls -d "$H"/coord.* 2>/dev/null | grep -c .)"
TMPDIR=$H bash -c '. "$1"; mktask' _ "$ROOT/tests/lib.sh" >/dev/null
eq "the next run removes it" "" "$(ls "$H" | grep -v '^out$')"

# A fixture whose test still runs is never touched.
TMPDIR=$H bash -c '. "$1"; mktask; echo "$_TMPROOT"; sleep 3' _ "$ROOT/tests/lib.sh" > "$H/out" &
live=$!
i=0; while [ ! -s "$H/out" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
TMPDIR=$H bash -c '. "$1"; mktask' _ "$ROOT/tests/lib.sh" >/dev/null
ok "a running test's fixture is kept" test -d "$(head -1 "$H/out")"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
eq "and removed when that test stops" "" "$(ls "$H" | grep -v '^out$')"
