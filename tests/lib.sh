ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
: "${TMPDIR:=/tmp}"
PASS=0; FAIL=0; _TMPROOT=""; _TMPROOTS=""
# Harmless fakes first on PATH, so no test reaches the machine's container engine, browser tool, agent programs
# or local models, hung or not; a test that installs its own puts them in front of these.
FAKES=$(mktemp -d "${TMPDIR%/}/coordfake.XXXXXX"); FAKES=$(cd "$FAKES" && pwd -P); echo "$$" > "$FAKES/.owner"
for _f in docker dev-browser t3 ollama lms llama-server claude codex gemini opencode agent cursor-agent aider \
  goose amp qwen pi kiro-cli copilot; do printf '#!/bin/sh\nexit 0\n' > "$FAKES/$_f"; chmod +x "$FAKES/$_f"; done
PATH=$FAKES:$PATH; COORD_APPS_DIR=$FAKES/apps; COORD_NO_NET_PROBE=1; export PATH COORD_APPS_DIR COORD_NO_NET_PROBE
ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $d"; fi; }
fails() { local want=$1 d=$2 got; shift 2; "$@" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $d (exit $got, wanted $want)"; fi; }
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fi; }
# Temporary coordinator root (FIX) with a copy of config/ and a private data folder, beside two fake
# folders outside it (CO is company scope, PE is personal), so tests never touch real records or paths.
# Providers: claude is a company account, codex personal, localmodel local.
# Each fixture records its test's pid, so a later run can remove the fixture of a test killed outright.
_reap_fixtures() { local d pid
  for d in "${TMPDIR%/}"/coord.* "${TMPDIR%/}"/coordfake.*; do
    [ -f "$d/.owner" ] || continue; read -r pid < "$d/.owner" || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -rf "$d"
  done; }
mktask() { _reap_fixtures; _TMPROOT=$(mktemp -d "${TMPDIR%/}/coord.XXXXXX"); _TMPROOT=$(cd "$_TMPROOT" && pwd -P)
  echo "$$" > "$_TMPROOT/.owner"; _TMPROOTS="$_TMPROOTS $_TMPROOT"
  FIX=$_TMPROOT/coord; CO=$_TMPROOT/company; PE=$_TMPROOT/personal
  mkdir -p "$FIX/.private/tasks" "$FIX/.private/config" "$CO/team/service" "$PE/app"
  cp -R "$ROOT/config" "$FIX/"
  printf '%s\tclaude\tcompany\n*\tcodex\tpersonal\n' "$CO" > "$FIX/.private/config/routing.tsv"
  printf 'claude\tcompany\t-\t-\t-\t-\ncodex\tpersonal\t-\t-\t-\t-\nlocalmodel\tlocal\t-\t-\t-\t-\n' \
    > "$FIX/.private/config/providers.tsv"
  printf 'company\tcompany\npersonal\tpersonal,company,local\n' > "$FIX/.private/config/scopes.tsv"
  COORD_ROOT=$FIX; COORD_DATA=$FIX/.private; export COORD_ROOT COORD_DATA; }
_finish() { local d; for d in $_TMPROOTS; do rm -rf "$d"; done; rm -rf "$FAKES"; echo "RESULT $PASS $FAIL"; }
trap _finish EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
