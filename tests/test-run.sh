. "$(dirname "$0")/lib.sh"; mktask; T=$_TMPROOT/t; mkdir -p "$T"
# run.sh prints a line per file as it ends, so a long run is never silent.
printf 'echo "RESULT 3 0"\n' > "$T/test-good.sh"
printf 'echo "FAIL: one check"\necho "RESULT 1 1"\n' > "$T/test-bad.sh"
printf 'exit 1\n' > "$T/test-dead.sh"
out=$(bash "$ROOT/tests/run.sh" "$T/test-good.sh" "$T/test-bad.sh" "$T/test-dead.sh"); code=$?
eq "one line per file, failing lines kept, total last" \
  "test-good.sh: pass 3, fail 0|test-bad.sh: FAIL: one check|test-bad.sh: pass 1, fail 1|test-dead.sh: crashed|PASS 4 / FAIL 2" \
  "$(printf '%s\n' "$out" | paste -sd'|' -)"
eq "a failure exits 1" 1 "$code"
eq "all passing exits 0" "0 PASS 3 / FAIL 0" "$(o=$(bash "$ROOT/tests/run.sh" "$T/test-good.sh"); echo "$? $(printf '%s\n' "$o" | tail -1)")"
