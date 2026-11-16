. "$(dirname "$0")/lib.sh"; mktask; R="$ROOT/scripts/route.sh"; S="$ROOT/scripts"; X=$(dirname "$CO")
eq "company repo" claude "$($R provider "$CO/team/service")"
eq "personal repo" codex "$($R provider "$PE/app")"
eq "boundary" codex "$($R provider "$CO-notes")"
eq "scope" company "$($R scope "$CO/team/service/")"
ok "claude on personal allowed" $R check claude "$PE/app"
fails 1 "codex on company refused" $R check codex "$CO/team/service"
fails 1 "dot-dot refused" $R check codex "$CO/../company/team"
ln -s "$CO" "$X/link"
fails 1 "symlink refused" $R check codex "$X/link/team"
fails 1 "dot-dot through a missing folder refused" $R check codex "$X/nope/../company/team"
fails 2 "usage" $R check codex
# The volume is case-insensitive: a differently cased path is the same company folder.
fails 1 "case variant refused" $R check codex "$X/Company/team"
fails 1 "upper case refused" $R check codex "$(printf %s "$CO" | tr a-z A-Z)/team/service"
eq "case variant is company" claude "$($R provider "$(printf %s "$CO" | tr A-Z a-z)")"
fails 2 "empty path is bad usage" $R check codex ""

# Account kinds.
fails 1 "provider missing from the table counts as personal" $R check newcomer "$CO/team/service"
ok "provider missing from the table is personal in a personal folder" $R check newcomer "$PE/app"
printf 'company\tcompany,local\npersonal\tpersonal,company\n' > "$COORD_DATA/config/scopes.tsv"
ok "local accepted where the scope lists local" $R check localmodel "$CO/team/service"
fails 1 "local refused where the scope does not list it" $R check localmodel "$PE/app"
printf 'company\tcompany\npersonal\tpersonal,company,local\n' > "$COORD_DATA/config/scopes.tsv"
fails 1 "local refused in a company scope by default" $R check localmodel "$CO/team/service"

# Tasks and the coordinator's own folder.
P=$($S/task-new.sh personal - blog "Blog")
ok "codex in the coordinator folder with only personal records" $R check codex "$FIX"
ok "codex for a personal task" $R check-task codex "$P"
D=$($S/task-new.sh company ACME-1 api "API")
fails 1 "codex refused for a company task" $R check-task codex "$D"
fails 1 "codex refused for a company task even in a personal repo" $S/agent-add.sh "$D" worker codex m medium "$PE/app" - - thr_1
fails 1 "codex refused in the coordinator folder while a company record exists" $R check codex "$FIX/scripts"
fails 1 "the data folder counts as the coordinator's" $R check codex "$COORD_DATA/tasks"
ok "claude allowed in the coordinator folder" $R check claude "$FIX"
eq "pick: company task, sub-coordinator in the coordinator folder" claude "$($R pick "$D")"
eq "pick: repo provider" claude "$($R pick "$D" "$CO/team/service")"
eq "pick: personal repo for a company task falls back" claude "$($R pick "$D" "$PE/app")"
eq "pick: personal task, personal repo" codex "$($R pick "$P" "$PE/app")"
eq "pick: personal task while a company record exists" claude "$($R pick "$P")"
rm -r "$D"
ok "codex accepted again once no company record exists" $R check codex "$FIX/scripts"
eq "pick: personal task" codex "$($R pick "$P")"
printf 'personal\tcompany\n' > "$COORD_DATA/config/scopes.tsv"
fails 1 "the folder's own scope still applies" $R check codex "$FIX"
fails 2 "pick usage" $R pick
fails 2 "check-task needs a task folder" $R check-task codex "$PE/app"

# Missing scopes.tsv fails closed.
rm "$COORD_DATA/config/scopes.tsv"
fails 1 "no scopes.tsv: company accepts only its routed kind" $R check codex "$CO/team/service"
ok "no scopes.tsv: routed provider still accepted" $R check claude "$CO/team/service"
fails 1 "no scopes.tsv: personal no longer accepts company" $R check claude "$PE/app"
printf 'codex\tpersonal\t-\t-\t-\t-\n' > "$COORD_DATA/config/providers.tsv"
fails 1 "no scopes.tsv, routed provider without a kind: nothing accepted" $R check codex "$CO/team/service"
rm "$COORD_DATA/config/providers.tsv"
fails 1 "no tables at all: refused" $R check codex "$CO/team/service"
fails 1 "no tables at all: pick finds nothing" $R pick "$P"

rm "$COORD_DATA/config/routing.tsv"
fails 2 "missing routing table is named, not guessed" $R provider "$PE/app"

# The routing table: a company row in any written form still routes as company.
printf 'claude\tcompany\t-\t-\t-\t-\ncodex\tpersonal\t-\t-\t-\t-\n' > "$COORD_DATA/config/providers.tsv"
printf 'company\tcompany\npersonal\tpersonal,company,local\n' > "$COORD_DATA/config/scopes.tsv"
rt() { printf '%s\n' "$@" > "$COORD_DATA/config/routing.tsv"; }
rt "$X/link/	claude	company" "*	codex	personal"
eq "row through a symlink, trailing slash: company" company "$($R scope "$CO/team")"
fails 1 "row through a symlink: codex refused" $R check codex "$CO/team"
HOME=$X rt "~/company	claude	company" "*	codex	personal"
eq "row under ~: company" company "$(HOME=$X $R scope "$CO/team")"
fails 1 "row under ~: codex refused" env HOME=$X $R check codex "$CO/team"
rt "# a comment" "" "$CO	claude	company" "*	codex	personal"
eq "comments and blank lines skipped" company "$($R scope "$CO")"
rt "$CO claude company" "*	codex	personal"
fails 2 "spaces instead of tabs: every call fails" $R scope "$PE/app"
eq "the bad row is named" "$COORD_DATA/config/routing.tsv line 1: not three tab-separated fields (path, provider, scope)" "$($R check claude "$PE/app" 2>&1)"
rt "*	codex	personal" "$CO	claude"
fails 2 "two fields: every call fails" $R provider "$PE/app"
rt "$CO	claude	company	extra" "*	codex	personal"
fails 2 "four fields: every call fails" $R provider "$PE/app"
rt "$CO	claude	company"$'\r' "*	codex	personal"
fails 2 "carriage return: every call fails" $R provider "$PE/app"
eq "a carriage return has its own message" "$COORD_DATA/config/routing.tsv line 1: ends with CR (Windows line ends): save with LF" "$($R provider "$PE/app" 2>&1)"
rt "$X/missing	claude	company" "*	codex	personal"
fails 2 "missing folder: every call fails" $R provider "$PE/app"
ok "missing folder: the line is named" grep -q 'line 1: the folder .* does not exist' <<< "$($R scope "$PE/app" 2>&1)"
rt "company	claude	company" "*	codex	personal"
fails 2 "relative path: every call fails" $R scope "$PE/app"
rt "$CO	claude	company" "*	codex	personal"

# On macOS a folder spelled through the data volume is the same folder as its plain path.
if [ -d /System/Volumes/Data ] && [ /System/Volumes/Data"$CO" -ef "$CO" ]; then
  V=/System/Volumes/Data
  eq "a company folder through the data volume: company" company "$($R scope "$V$CO/team")"
  fails 1 "a company folder through the data volume refuses codex" $R check codex "$V$CO/team"
  eq "a path under it that does not exist yet: company" company "$($R scope "$V$CO/team/new/x")"
  eq "physical drops the volume prefix" "$CO/team" "$(bash -c '. "$1"; physical "$2"' _ "$S/lib.sh" "$V$CO/team")"
  rt "$V$CO	claude	company" "*	codex	personal"
  eq "a row spelled through the data volume" company "$($R scope "$CO/team")"
  rt "$CO	claude	company" "*	codex	personal"
fi

# check-task looks at every repository the task names, not only at its scope.
P2=$($S/task-new.sh personal - mixed "Mixed")
ok "personal task: codex" $R check-task codex "$P2"
$S/task-set.sh "$P2" repositories "$PE/app, $CO/team/service"
fails 1 "a company repository of a personal task refuses codex" $R check-task codex "$P2"
ok "the company provider still passes" $R check-task claude "$P2"
eq "pick skips codex" claude "$($R pick "$P2")"
$S/task-set.sh "$P2" repositories "the api ($CO/team/service) and $PE/app"
fails 1 "a path inside free text is found" $R check-task codex "$P2"
$S/task-set.sh "$P2" repositories "<company-repo>, $PE/app"
ok "names that are not paths are ignored" $R check-task codex "$P2"

# The coordinator's folder, reached from a worktree of it.
if git --version >/dev/null 2>&1; then
  M=$_TMPROOT/main; mkdir -p "$M/scripts" "$M/.private/tasks/company/t1" "$M/.private/config"
  cp "$COORD_DATA"/config/*.tsv "$M/.private/config/"; : > "$M/.private/tasks/company/t1/task.md"
  printf '.private/\n.claude/\n' > "$M/.gitignore"; cp -R "$FIX/config" "$M/"
  git init -q "$M" && git -C "$M" add -A >/dev/null 2>&1
  git -C "$M" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null commit -q -m init >/dev/null 2>&1
  git -C "$M" worktree add -q "$M/.claude/worktrees/w" >/dev/null 2>&1
  git -C "$M" worktree add -q "$_TMPROOT/w2" >/dev/null 2>&1
  W=$M/.claude/worktrees/w
  fromwt() { env -u COORD_DATA COORD_ROOT=$W "$@"; }
  eq "the worktree reads the main data" company "$(fromwt $R scope "$CO")"
  fails 1 "from a worktree: the main checkout refuses codex" fromwt $R check codex "$M"
  fails 1 "from a worktree: the main scripts refuse codex" fromwt $R check codex "$M/scripts"
  fails 1 "from a worktree: another worktree refuses codex" fromwt $R check codex "$_TMPROOT/w2"
  fails 1 "from the main checkout: a worktree refuses codex" env COORD_ROOT=$M COORD_DATA=$M/.private $R check codex "$W"
  ok "from a worktree: a personal repo still passes" fromwt $R check codex "$PE/app"
  rm -f "$M/.private/tasks/company/t1/task.md"
  ok "no company record: the main checkout accepts codex" fromwt $R check codex "$M"
fi
