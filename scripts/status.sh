#!/bin/bash
# status.sh [--live]  ->  what finished since last time, then the board
set -u
. "$(dirname "$0")/lib.sh"
case "${1:-}" in --live|'') ;; *) die 2 "usage: status.sh [--live]" ;; esac
[ $# -le 1 ] || die 2 "usage: status.sh [--live]"
"$SCRIPTS/report.sh"
echo
"$SCRIPTS/board.sh" ${1:+"$1"} || die 1 "board not rebuilt"
cat "$DATA/board.md"
