. "$(dirname "$0")/lib.sh"; H="$ROOT/scripts/health.sh"
# Every test runs on a fixture: fake docker/df/ps first on PATH, an empty browser home, no real readings.
mktask; B=$FIX/bin; mkdir -p "$B" "$FIX/bh"; export BROWSER_HOME=$FIX/bh PATH="$B:$PATH"
printf '#!/bin/sh\n[ -f "$FIX/ps.txt" ] && cut -d" " -f2- "$FIX/ps.txt"; exit 0\n' > "$B/ps"
printf '#!/bin/sh\ncat "$FIX/docker.txt"\n' > "$B/docker"
chmod +x "$B"/*; : > "$FIX/docker.txt"; export FIX
R=(HEALTH_DISK_FREE_GB=40 HEALTH_MEM_FREE_PCT=35)
ok "healthy" env "${R[@]}" HEALTH_CONTAINERS=4 $H
fails 1 "low disk" env HEALTH_DISK_FREE_GB=7 HEALTH_MEM_FREE_PCT=35 HEALTH_CONTAINERS=4 $H
eq "reason named" "unhealthy: disk" "$(HEALTH_DISK_FREE_GB=7 HEALTH_MEM_FREE_PCT=35 HEALTH_CONTAINERS=4 $H 2>/dev/null | tail -1)"
fails 1 "threshold is inclusive-fail below" env HEALTH_DISK_FREE_GB=14 HEALTH_MEM_FREE_PCT=20 HEALTH_CONTAINERS=12 $H
ok "exactly at thresholds" env HEALTH_DISK_FREE_GB=15 HEALTH_MEM_FREE_PCT=20 HEALTH_CONTAINERS=12 $H
# An engine that does not answer is shown as unknown and stops nothing; disk and memory still decide.
ok "containers unknown is not unhealthy" env "${R[@]}" HEALTH_CONTAINERS=unknown $H
eq "containers unknown line" "containers=unknown max=12 unknown" "$(env "${R[@]}" HEALTH_CONTAINERS=unknown $H | sed -n 3p)"
eq "containers unknown does not hide low disk" "unhealthy: disk" "$(env HEALTH_DISK_FREE_GB=7 HEALTH_MEM_FREE_PCT=35 HEALTH_CONTAINERS=unknown $H 2>/dev/null | tail -1)"
fails 1 "memory unknown is still unhealthy" env HEALTH_DISK_FREE_GB=40 HEALTH_MEM_FREE_PCT=unknown HEALTH_CONTAINERS=4 $H
ok "containers unknown in json" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["verdict"]=="healthy"; assert {"name":"containers","value":"unknown","limit":"12","state":"unknown"} in d["readings"]' "$(env "${R[@]}" HEALTH_CONTAINERS=unknown $H --json)"
OUT=$(env "${R[@]}" HEALTH_CONTAINERS=4 $H)
eq "first three lines unchanged" "disk_free_gb=40 min=15 ok|mem_free_pct=35 min=20 ok|containers=4 max=12 ok" "$(echo "$OUT" | head -3 | paste -sd'|' -)"
ok "one line per resource row" grep -qx 'resource.browsers=0 max=6 ok' <<< "$OUT"
eq "resource lines count" "$(grep -vc '^#' "$FIX/config/resources.tsv")" "$(grep -c '^resource\.' <<< "$OUT")"

# Docker: absent reads 0, present and answering is counted, present and silent is unknown.
printf 'a1\nb2\n' > "$FIX/docker.txt"
eq "docker counted" "containers=2 max=12 ok" "$(env "${R[@]}" $H | sed -n 3p)"
printf '#!/bin/sh\nexit 1\n' > "$B/docker"
eq "docker failing is unknown" "containers=unknown max=12 unknown" "$(env "${R[@]}" $H 2>/dev/null | sed -n 3p)"
# A hanging engine with a child of its own: cut at its own short limit, nothing left, even when health.sh is killed.
printf '#!/bin/sh\nsleep 4301 &\nsleep 4302\n' > "$B/docker"; printf 'CONTAINER_TIMEOUT_SEC=1\n' >> "$FIX/config/health.conf"
gone() { local i=0; while pgrep -f "$1" >/dev/null; do [ $i -lt 30 ] || return 1; sleep 0.1; i=$((i+1)); done; }
s0=$(date +%s); OUT=$(env "${R[@]}" $H 2>/dev/null); rc=$?
eq "docker hanging is unknown" "containers=unknown max=12 unknown" "$(echo "$OUT" | sed -n 3p)"
eq "docker hanging stops no launch" "0 healthy" "$rc $(echo "$OUT" | tail -1)"
ok "the short limit is used, not the resource one" test $(( $(date +%s) - s0 )) -lt 8
ok "the hanging docker is gone" gone 'sleep 4302'
ok "its child is gone" gone 'sleep 4301'
printf '#!/bin/sh\nsleep 4303 &\nsleep 4304\n' > "$B/docker"; printf 'CONTAINER_TIMEOUT_SEC=60\n' >> "$FIX/config/health.conf"
env "${R[@]}" $H >/dev/null 2>&1 & hp=$!
i=0; until pgrep -f 'sleep 4303' >/dev/null || [ $i -ge 30 ]; do sleep 0.1; i=$((i+1)); done
kill -TERM "$hp"; wait "$hp" 2>/dev/null
ok "health.sh killed: docker is gone" gone 'sleep 4304'
ok "health.sh killed: its child is gone" gone 'sleep 4303'
rm "$B/docker"
NODOCKER=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/docker" ] || echo "$d"; done | paste -sd: -)
eq "no docker means none used" "containers=0 max=12 ok" "$(env PATH="$NODOCKER" "${R[@]}" $H | sed -n 3p)"

# Linux readings: /proc/meminfo through an override, and POSIX df.
printf 'MemTotal:  16000000 kB\nMemFree:  100 kB\nMemAvailable:  4000000 kB\n' > "$FIX/meminfo"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/x 100 1 31457280 1%% /"\n' > "$B/df"; chmod +x "$B/df"
OUT=$(env PATH="$NODOCKER" HEALTH_MEMINFO="$FIX/meminfo" $H)
eq "disk from df -P" "disk_free_gb=30 min=15 ok" "$(echo "$OUT" | sed -n 1p)"
eq "memory from meminfo" "mem_free_pct=25 min=20 ok" "$(echo "$OUT" | sed -n 2p)"
printf 'MemTotal:  16000000 kB\n' > "$FIX/meminfo"
eq "meminfo without MemAvailable is unknown" "mem_free_pct=unknown min=20 unknown" "$(env PATH="$NODOCKER" HEALTH_MEMINFO="$FIX/meminfo" $H 2>/dev/null | sed -n 2p)"

# Resource rows: over the limit is unhealthy and named; a command that cannot run is unknown and not.
printf 'stuff\techo 9\t3\t-\t-\tauto\nbroken\tno-such-command-x\t3\t-\t-\tauto\n' > "$FIX/.private/config/resources.tsv"
OUT=$(env PATH="$NODOCKER" "${R[@]}" $H 2>/dev/null); rc=$?
eq "over limit fails" 1 "$rc"
ok "over limit line" grep -qx 'resource.stuff=9 max=3 HIGH' <<< "$OUT"
ok "unknown row line" grep -qx 'resource.broken=unknown max=3 unknown' <<< "$OUT"
eq "only the high row is a reason" "unhealthy: stuff" "$(echo "$OUT" | tail -1)"
printf 'browsers\techo 2\t1\t-\t-\tauto\n' > "$FIX/.private/config/resources.tsv"
ok "a private row overrides the tracked one" grep -qx 'resource.browsers=2 max=1 HIGH' <<< "$(env PATH="$NODOCKER" "${R[@]}" $H 2>/dev/null)"

# --json prints the board's health object and exits 0 once printed.
J=$(env PATH="$NODOCKER" "${R[@]}" $H --json); rc=$?
eq "json exit" 0 "$rc"
ok "json parses" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["verdict"]=="unhealthy: browsers"; assert d["readings"][0]=={"name":"disk_free_gb","value":"40","limit":"15","state":"ok"}' "$J"

printf 'MIN_FREE_DISK_GB=15GB\nMIN_FREE_MEM_PCT=20\nMAX_RUNNING_CONTAINERS=12\n' > "$COORD_ROOT/config/health.conf"
fails 2 "malformed threshold is not healthy" env HEALTH_DISK_FREE_GB=1 HEALTH_MEM_FREE_PCT=35 HEALTH_CONTAINERS=4 $H
