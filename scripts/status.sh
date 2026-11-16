#!/bin/bash
# status.sh [--live]  ->  what finished since last time (nothing when nothing did), then the board
set -u
. "$(dirname "$0")/lib.sh"
case "${1:-}" in --live|'') ;; *) die 2 "usage: status.sh [--live]" ;; esac
[ $# -le 1 ] || die 2 "usage: status.sh [--live]"
# report.sh says "nothing new" when the inbox is empty; here that is said by printing nothing.
r=$("$SCRIPTS/report.sh")
if [ -n "$r" ] && [ "$r" != "nothing new" ]; then printf '## Finished, not yet seen\n\n%s\n\n' "$r"; fi
"$SCRIPTS/board.sh" ${1:+"$1"} || die 1 "board not rebuilt"
cat "$DATA/board.md"
