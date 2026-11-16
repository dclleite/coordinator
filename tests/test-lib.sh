. "$(dirname "$0")/lib.sh"
. "$ROOT/scripts/lib.sh"
eq "json plain" '"abc"' "$(json_str abc)"
eq "json empty" '""' "$(json_str "")"
eq "json quotes and backslash" '"a \"q\" b\\c"' "$(json_str 'a "q" b\c')"
eq "json tab and newline" '"a\tb\nc"' "$(json_str "$(printf 'a\tb\nc')")"
eq "json drops control bytes" '"xy"' "$(json_str "$(printf 'x\001\033y')")"
# A worktree without a data folder resolves DATA to the main checkout's.
if git --version >/dev/null 2>&1; then
  mktask; W=$_TMPROOT/wt; mkdir -p "$W"
  git init -q "$W/main" && mkdir -p "$W/main/.private" "$W/main/scripts"
  cp "$ROOT/scripts/lib.sh" "$W/main/scripts/" && printf '.private/\n' > "$W/main/.gitignore"
  git -C "$W/main" add -A >/dev/null 2>&1
  git -C "$W/main" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null commit -q -m init >/dev/null 2>&1
  git -C "$W/main" worktree add -q "$W/wt" >/dev/null 2>&1
  eq "worktree shares the main data folder" "$W/main/.private" "$(env -u COORD_ROOT -u COORD_DATA bash -c '. "$1/wt/scripts/lib.sh"; echo "$DATA"' _ "$W")"
  eq "main checkout keeps its own" "$W/main/.private" "$(env -u COORD_ROOT -u COORD_DATA bash -c '. "$1/main/scripts/lib.sh"; echo "$DATA"' _ "$W")"
  eq "explicit data folder wins" "/x/y" "$(env -u COORD_ROOT COORD_DATA=/x/y bash -c '. "$1/wt/scripts/lib.sh"; echo "$DATA"' _ "$W")"
  rm -rf "$W"
fi

# The lock helper.
LK=$(mktemp -d "${TMPDIR%/}/coordlk.XXXXXX"); L=$LK/a.lock
# A holder that stays alive: the lock is its own until it ends, however old.
bash -c '. "$1"; lock_take "$2"; sleep 30' _ "$ROOT/scripts/lib.sh" "$L" & HP=$!
i=0; until [ -s "$L/owner" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i+1)); done; ok "taken" test -d "$L"
fails 1 "a held lock is waited for, then refused" env LOCK_WAIT_SEC=1 bash -c '. "$1"; lock_take "$2"' _ "$ROOT/scripts/lib.sh" "$L"
lock_drop "$L"; ok "another process's lock is not dropped" test -d "$L"
read -r tok _ < "$L/owner"; printf '%s %s %s\n' "$tok" "$(( $(date +%s) - 3600 ))" "$(proc_start "$HP")" > "$L/owner"
fails 1 "a live holder keeps an old lock" env LOCK_WAIT_SEC=1 bash -c '. "$1"; lock_take "$2"' _ "$ROOT/scripts/lib.sh" "$L"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
ok "a dead holder's lock is taken at once" env LOCK_WAIT_SEC=1 bash -c '. "$1"; lock_take "$2"' _ "$ROOT/scripts/lib.sh" "$L"
sleep 30 & HP=$!
printf '%s.1 %s\n' "$HP" "$(( $(date +%s) + 3600 ))" > "$L/owner"
fails 1 "an owner time in the future does not matter while the holder lives" env LOCK_WAIT_SEC=1 bash -c '. "$1"; lock_take "$2"' _ "$ROOT/scripts/lib.sh" "$L"
printf '%s.1 %s %s\n' "$HP" "$(date +%s)" "Thu Jan  1 00:00:00 1970" > "$L/owner"
ok "a reused id with another start time is not the holder" env LOCK_WAIT_SEC=1 bash -c '. "$1"; lock_take "$2"' _ "$ROOT/scripts/lib.sh" "$L"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
rm -rf "$L"; mkdir "$L"
fails 1 "a lock with no owner yet is waited for" env LOCK_WAIT_SEC=1 bash -c '. "$1"; lock_take "$2"' _ "$ROOT/scripts/lib.sh" "$L"
rm -rf "$L"; lock_take "$L"; ok "own lock" test -d "$L"; lock_drop "$L"; ok "own lock dropped" test ! -e "$L"
lock_drop "$L"; ok "dropping a missing lock is harmless" true
rm -rf "$LK"

# The hash helper gives the same digest with either tool.
eq "sha256" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(printf abc | sha256)"

# Every test reaches fakes, never the machine's own container engine, browser tool or agent programs.
for p in docker dev-browser t3 ollama claude codex gemini; do
  eq "$p is the fake" "$FAKES/$p" "$(command -v "$p")"
done
