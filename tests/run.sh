#!/bin/bash
# Runs every tests/test-*.sh (or the ones named as arguments) and sums the results.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
pass=0; fail=0
if [ $# -gt 0 ]; then files=("$@"); else files=("$here"/test-*.sh); fi
for f in "${files[@]}"; do
  out=$(bash "$f" 2>&1)
  res=$(printf '%s\n' "$out" | grep '^RESULT ' | tail -1)
  printf '%s\n' "$out" | grep -v '^RESULT ' | sed "s|^|$(basename "$f"): |" | grep -v ': $'
  if [ -z "$res" ]; then echo "$(basename "$f"): crashed"; fail=$((fail+1)); continue; fi
  set -- $res; pass=$((pass+$2)); fail=$((fail+$3))
done
echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
