. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts/service.sh"; SD=$COORD_DATA/services
eq "no services folder lists nothing" "" "$($S list)"
eq "no services is an empty JSON list" "[]" "$($S status --all --json)"
fails 2 "usage" $S
fails 2 "unknown subcommand" $S frobnicate
mkdir -p "$SD"
# An invented service whose commands are harmless; the state comes from a file the test controls.
cat > "$SD/acme.conf" <<'CONF'
scope=personal
status=cat state.txt
verb.ping=auto:echo pong
verb.touch=auto:touch touched.txt
verb.restart=confirm:touch restarted.txt
verb.restart.label=auto: touch labelran.txt
verb.restart.label.pt-BR=auto: touch labelran-pt.txt
verb.ping.label.pt-BR=Pingar "já"
verb.ping.label.pt-BR=a second line for the same language
verb.broken=nocolon
verb.odd=never:echo no
threads=thr_a, thr_b
protect=/srv/acme/prod,~/acme-cache-*
panel=http://127.0.0.1:9999/
CONF
printf 'ok\nqueue=0\n\nage=12s\n' > "$SD/state.txt"
eq "list" "acme scope=personal verbs=ping,touch,restart,broken,odd" "$($S list)"
eq "status text" "acme: ok
  queue=0
  age=12s
  panel: http://127.0.0.1:9999/" "$($S status acme)"
eq "status json" '{"name":"acme","state":"ok","detail":["queue=0","age=12s"],"panel":"http://127.0.0.1:9999/","verbs":[{"verb":"ping","class":"auto","label":"","labels":{"pt-BR":"Pingar \"já\""}},{"verb":"touch","class":"auto","label":"","labels":{}},{"verb":"restart","class":"confirm","label":"auto: touch labelran.txt","labels":{"pt-BR":"auto: touch labelran-pt.txt"}}]}' "$($S status acme --json)"
fails 1 "JSON never carries a command" grep -q "restarted.txt" <<< "$($S status --all --json)"
printf 'degraded\nloop "x" late\n' > "$SD/state.txt"
eq "detail is JSON-escaped" '[{"name":"acme","state":"degraded","detail":["loop \"x\" late"],"panel":"http://127.0.0.1:9999/","verbs":[{"verb":"ping","class":"auto","label":"","labels":{"pt-BR":"Pingar \"já\""}},{"verb":"touch","class":"auto","label":"","labels":{}},{"verb":"restart","class":"confirm","label":"auto: touch labelran.txt","labels":{"pt-BR":"auto: touch labelran-pt.txt"}}]}]' "$($S status --all --json)"
printf 'healthy\n' > "$SD/state.txt"
eq "a word outside the three reads unknown" "unknown" "$($S status acme --json | sed 's/.*"state":"\([a-z]*\)".*/\1/')"
printf 'ok\n' > "$SD/state.txt"; echo 'status=cat state.txt; exit 3' > "$SD/fail.conf"
eq "a failing status reads unknown" "fail: unknown
  status command failed (exit 3)" "$($S status fail)"
echo 'scope=personal' > "$SD/fail.conf"
eq "no status command reads unknown" "fail: unknown
  the binding has no status command" "$($S status fail)"
rm "$SD/fail.conf"
# The timeout kills the whole status command, its children included, and reads unknown.
printf 'status=sleep 37; echo ok\n' > "$SD/slow.conf"
eq "timeout reads unknown" "slow: unknown
  status timed out after 1s" "$(SERVICE_STATUS_TIMEOUT=1 $S status slow)"
fails 1 "nothing left running after a timeout" pgrep -f "sleep 37"
rm "$SD/slow.conf"
fails 2 "bad timeout" env SERVICE_STATUS_TIMEOUT=x $S status acme
fails 2 "unknown service" $S status nope
fails 2 "a name cannot leave the folder" $S status ../acme
eq "status keeps no output on disk" "acme.conf state.txt" "$(ls "$SD" | paste -sd' ' -)"
# run: auto verbs run, confirm verbs need --confirmed, every attempt is logged without output.
eq "auto verb runs" "pong" "$($S run acme ping)"
$S run acme touch; ok "auto verb ran in the services folder" test -f "$SD/touched.txt"
fails 1 "confirm verb refused without --confirmed" $S run acme restart
fails 1 "refusal left nothing done" test -f "$SD/restarted.txt"
ok "confirm verb runs with --confirmed" $S run acme restart --confirmed
ok "confirmed verb ran" test -f "$SD/restarted.txt"
fails 2 "unknown verb" $S run acme dance
fails 2 "verb without a class" $S run acme broken
fails 2 "class outside auto and confirm" $S run acme odd
fails 2 "stray argument" $S run acme ping --now
fails 2 "a label line is never a verb" $S run acme restart.label
fails 1 "and its text never ran" test -f "$SD/labelran.txt"
fails 2 "a label line of one language is never a verb" $S run acme restart.label.pt-BR
fails 1 "and its text never ran either" test -f "$SD/labelran-pt.txt"
echo 'verb.exit=auto:exit 4' >> "$SD/acme.conf"
fails 4 "run returns the command's exit code" $S run acme exit
eq "log columns" "ping 0|touch 0|restart refused|restart 0|exit 4" "$(cut -f2,3 "$SD/acme.log" | tr '\t' ' ' | paste -sd'|' -)"
fails 1 "log holds no output text" grep -q pong "$SD/acme.log"
# protected: the union of every binding, trimmed, ~ expanded, without repeats.
printf 'threads=thr_b,thr_c\nprotect=/srv/other\n' > "$SD/other.conf"
eq "protected threads" "thr_a thr_b thr_c" "$($S protected threads | paste -sd' ' -)"
eq "protected paths" "/srv/acme/prod $HOME/acme-cache-* /srv/other" "$($S protected paths | paste -sd' ' -)"
fails 2 "protected needs a kind" $S protected
