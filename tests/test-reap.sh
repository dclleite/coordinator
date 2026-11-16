. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; RP=$S/reap.sh
# Fakes as in test-browser.sh, plus a fake launchctl: no real browser, daemon or scheduler entry.
B=$FIX/bin; BH=$FIX/bh; PS=$FIX/ps.txt; mkdir -p "$B" "$BH/browsers" "$BH/tmp" "$FIX/scripts"; : > "$BH/daemon.sock"
export BROWSER_HOME=$BH PS LOG=$FIX/log.txt; : > "$LOG"
printf '#!/bin/sh\ncase "$*" in *etime*) cat "$PS" ;; *) cut -d" " -f2- "$PS" ;; esac\n' > "$B/ps"
printf '#!/bin/bash\necho "tool $*" >> "$LOG"\n' > "$B/dev-browser"
printf '#!/bin/bash\necho "node-stop $B" >> "$LOG"; grep -v "browsers/$B/" "$PS" > "$PS.n"; mv "$PS.n" "$PS"\n' > "$B/node"
printf '#!/bin/bash\necho "launchctl $*" >> "$LOG"\n' > "$B/launchctl"
chmod +x "$B"/*; export PATH="$B:$PATH"
proc() { echo "$1 /c --user-data-dir=$BH/browsers/$2/chromium-profile"; }
{ proc 10:00:00 a; proc 02:00:00 b; proc 01:00:00 c; proc 01:00:00 d; } > "$PS"
cat > "$FIX/config/resources.tsv" <<'T'
browsers	"$SCRIPTS"/browser.sh count	2	"$SCRIPTS"/browser.sh list	"$SCRIPTS"/browser.sh stop-name {id}	auto
careful	echo 9	1	echo k1	echo "{id}" >> "$ROOT/stops.log"	confirm
T
D=$($S/task-new.sh personal - web "Web"); $S/resource-add.sh "$D" browsers d thr_1 >/dev/null
touch "$BH/tmp/new.jpg"; touch -t 202001010000 "$BH/tmp/old.jpg"

OUT=$($RP --dry-run); rc=$?
eq "dry-run exit" 0 "$rc"
eq "dry-run plan" "$(printf 'would stop browsers a: no open task owns it and 4 are running (limit 2)\nwould stop browsers b: no open task owns it and 3 are running (limit 2)\ntmp_old=1 would delete\nstopped=0 failed=0 tmp_old=1')" "$OUT"
ok "dry-run stopped nothing" test -z "$(cat "$LOG")"
ok "dry-run kept tmp" test -f "$BH/tmp/old.jpg"
fails 1 "dry-run writes no log" test -f "$COORD_DATA/reap.log"

OUT=$($RP)
eq "stopped oldest unowned down to the limit" "$(printf 'node-stop a\nnode-stop b')" "$(cat "$LOG")"
eq "owned and newest kept" "$(printf 'c\nd')" "$($S/browser.sh list)"
ok "old tmp deleted" test ! -f "$BH/tmp/old.jpg"
ok "new tmp kept" test -f "$BH/tmp/new.jpg"
ok "confirm row untouched" test ! -f "$FIX/stops.log"
ok "logged" grep -q $'\tstopped=2 failed=0 tmp_old=1$' "$COORD_DATA/reap.log"
ok "never a global stop" test -z "$(grep '^tool' "$LOG")"
eq "nothing to act on: only the summary" "stopped=0 failed=0 tmp_old=0" "$($RP --dry-run)"
eq "nothing deleted: only the summary" "stopped=0 failed=0 tmp_old=0" "$($RP)"

# Under the limit, only age stops an unowned browser; an owned one is never stopped.
{ proc 07:00:00 e; proc 1-00:00:00 d; } >> "$PS"; : > "$LOG"
printf 'browsers\t"$SCRIPTS"/browser.sh count\t10\t"$SCRIPTS"/browser.sh list\t"$SCRIPTS"/browser.sh stop-name {id}\tauto\n' > "$COORD_DATA/config/resources.tsv"
$RP >/dev/null
eq "old unowned stopped, owned old kept" "node-stop e" "$(cat "$LOG")"

# A pid-file kind stopped by a repository script is reaped by the same rule.
P=$(sh -c 'sleep 60 >/dev/null 2>&1 & echo $!'); echo $P > "$COORD_DATA/widget.pid"
printf '#!/bin/bash\nkill "$(cat "$DATA/widget.pid")" && rm -f "$DATA/widget.pid"\n' > "$FIX/scripts/widget.sh"; chmod +x "$FIX/scripts/widget.sh"
printf 'widget\t[ -f "$DATA/widget.pid" ] && echo 1 || echo 0\t0\tcat "$DATA/widget.pid" 2>/dev/null || true\t"$ROOT"/scripts/widget.sh stop\tauto\n' >> "$COORD_DATA/config/resources.tsv"
ok "pid kind reaped" grep -qx "stopped widget $P: no open task owns it and 1 are running (limit 0)" <<< "$($RP)"
sleep 0.2; fails 1 "process gone" kill -0 $P; kill $P 2>/dev/null

# A stop that fails is reported and fails the run.
printf 'x\techo 2\t1\techo x1\tfalse\tauto\n' > "$COORD_DATA/config/resources.tsv"
fails 1 "failed stop" $RP
fails 2 "bad usage" $RP --now

# Scheduler entry: launchd plist in an override folder through the fake launchctl; Linux prints the cron line.
export REAP_LAUNCHD_DIR=$FIX/agents; : > "$LOG"
ok "install" env REAP_OS=Darwin $RP install
P=$REAP_LAUNCHD_DIR/local.coordinator.reap.plist
ok "plist written" grep -q '<integer>600</integer>' "$P"
ok "plist runs reap" grep -q "<string>$S/reap.sh</string>" "$P"
ok "bootstrapped" grep -q "^launchctl bootstrap gui/[0-9]* $P$" "$LOG"
command -v plutil >/dev/null && ok "plist is valid" plutil -lint "$P"
ok "uninstall" env REAP_OS=Darwin $RP uninstall
fails 1 "plist removed" test -f "$P"
ok "booted out" grep -q '^launchctl bootout gui/[0-9]*/local.coordinator.reap$' "$LOG"
eq "linux cron line" "*/10 * * * * /bin/bash $S/reap.sh >/dev/null 2>&1" "$(REAP_OS=Linux $RP install | tail -1)"
