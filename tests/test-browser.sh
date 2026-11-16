. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts"; W=$S/browser.sh
# A fake browser tool, process table and node: the tool "opens" a browser by adding a process line,
# node "stops" it by removing the line. No real browser or daemon is ever started.
B=$FIX/bin; BH=$FIX/bh; PS=$FIX/ps.txt; mkdir -p "$B" "$BH/browsers" "$BH/tmp"; : > "$PS"; : > "$BH/daemon.sock"
export BROWSER_HOME=$BH PS LOG=$FIX/log.txt
cat > "$B/ps" <<'F'
#!/bin/sh
case "$*" in *etime*) cat "$PS" ;; *) cut -d' ' -f2- "$PS" ;; esac
F
cat > "$B/dev-browser" <<'F'
#!/bin/bash
echo "tool $*" >> "$LOG"; [ "$1" = --browser ] || exit 3
grep -q "browsers/$2/" "$PS" || echo "00:05 /chromium --user-data-dir=$BROWSER_HOME/browsers/$2/chromium-profile" >> "$PS"
mkdir -p "$BROWSER_HOME/browsers/$2"; read -r line && echo "stdin $line" >> "$LOG"; exit 0
F
cat > "$B/node" <<'F'
#!/bin/bash
echo "node-stop $B" >> "$LOG"; grep -v "browsers/$B/" "$PS" > "$PS.n"; mv "$PS.n" "$PS"
F
chmod +x "$B"/*; export PATH="$B:$PATH"
D=$($S/task-new.sh personal - web "Web")

eq "name" "web-worker-1" "$($W name "$D" "worker 1")"
eq "nothing running" 0 "$($W count)"
OUT=$(echo "go" | $W run "$D" worker -- --headless); rc=$?
eq "run exit" 0 "$rc"
ok "tool got the name" grep -qx 'tool --browser web-worker --headless' "$LOG"
ok "stdin passed" grep -qx 'stdin go' "$LOG"
ok "own browser stopped" grep -qx 'node-stop web-worker' "$LOG"
eq "nothing left" 0 "$($W count)"
eq "record closed" "browsers web-worker closed" "$(awk -F'\t' '{print $1, $2, ($5=="-" ? "open" : "closed")}' "$D/resources.tsv")"

: > "$LOG"; echo x | $W run "$D" keeper --keep >/dev/null
eq "keep leaves it running" "keeper" "$($W list | sed 's/^web-//')"
ok "no stop on keep" test -z "$(grep node-stop "$LOG")"
ok "record open" grep -q $'^browsers\tweb-keeper\t.*\t-$' "$D/resources.tsv"
eq "age" 5 "$($W age web-keeper)"
ok "stop by agent" $W stop "$D" keeper
eq "stopped" 0 "$($W count)"
ok "record closed after stop" test -z "$(awk -F'\t' '$5=="-"' "$D/resources.tsv")"
eq "stop-name of a stopped browser" "not running: web-keeper" "$($W stop-name web-keeper)"

# The limit counts every running browser; a browser already running under the same name is reused.
printf 'browsers\t"$SCRIPTS"/browser.sh count\t2\t"$SCRIPTS"/browser.sh list\t-\tauto\n' > "$COORD_DATA/config/resources.tsv"
printf '1-02:00:00 /c --user-data-dir=%s/browsers/a/chromium-profile\n00:01 /c --type=renderer --user-data-dir=%s/browsers/b/chromium-profile\n' "$BH" "$BH" > "$PS"
eq "count by profile" 2 "$($W count)"
eq "age with days" 93600 "$($W age a)"
fails 1 "past the limit" sh -c "echo x | $W run '$D' third"
ok "refusal says why" grep -q 'browser limit reached (2 of 2' <<< "$(echo x | $W run "$D" third 2>&1)"
echo "00:01 /c --user-data-dir=$BH/browsers/web-third/chromium-profile" >> "$PS"
printf 'browsers\t"$SCRIPTS"/browser.sh count\t3\t"$SCRIPTS"/browser.sh list\t-\tauto\n' > "$COORD_DATA/config/resources.tsv"
ok "same name reused at the limit" sh -c "echo x | $W run '$D' third"
fails 2 "--browser refused" $W run "$D" w --browser other
fails 2 "bad name refused" $W stop-name ../x

# Profiles and temporary files.
: > "$PS"; mkdir -p "$BH/browsers/old" "$BH/browsers/live"
echo "00:01 /c --user-data-dir=$BH/browsers/live/chromium-profile" > "$PS"
ok "profiles listed" grep -qx old <<< "$($W profiles)"
fails 1 "running profile kept" $W profile-rm live
ok "idle profile removed" $W profile-rm old
fails 1 "gone" test -d "$BH/browsers/old"
touch "$BH/tmp/new.jpg"; touch -t 202001010000 "$BH/tmp/old.jpg"
eq "tmp count" 2 "$($W tmp-count)"
eq "dry run" "tmp_old=1 would delete" "$($W tmp-clean 2 --dry-run)"
ok "dry run kept it" test -f "$BH/tmp/old.jpg"
eq "clean" "tmp_old=1 deleted" "$($W tmp-clean 2)"
ok "new kept" test -f "$BH/tmp/new.jpg"; fails 1 "old gone" test -f "$BH/tmp/old.jpg"

# Tool missing: the wrapper says so and exits 2; reading still works.
rm "$B/dev-browser"
NOTOOL=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/dev-browser" ] || echo "$d"; done | paste -sd: -)
fails 2 "not installed" env PATH="$NOTOOL" $W run "$D" w
ok "message" grep -q 'browser tool not installed' <<< "$(env PATH="$NOTOOL" $W run "$D" w 2>&1)"
eq "count works without the tool" 1 "$(env PATH="$NOTOOL" $W count)"
