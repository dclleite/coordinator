. "$(dirname "$0")/lib.sh"; mktask; S="$ROOT/scripts/setup.sh"
# Provider detection also looks under HOME: an empty one keeps the machine's agent programs out of reach.
HOME=$_TMPROOT/home; mkdir -p "$HOME"; export HOME
# A fresh clone: no private folder at all.
rm -rf "$COORD_DATA"
G() { git -C "$FIX" "$@"; }
G init -q; printf '.private/\n' > "$FIX/.gitignore"
fails 2 "unknown option refused" $S --nope
fails 1 "check on a fresh clone reports work to do" $S --check
ok "check announces the discovered terms" grep -q '^would add: ' <<< "$($S --check 2>&1)"
fails 1 "check created nothing" test -e "$COORD_DATA"
eq "check set no hooks path" "" "$(G config core.hooksPath)"
out=$(PATH=/usr/bin:/bin $S 2>&1); code=$?
eq "setup succeeds with only the system tools" 0 "$code"
ok "routing copied from the example" cmp "$FIX/config/routing.example.tsv" "$COORD_DATA/config/routing.tsv"
ok "term list created" test -f "$COORD_DATA/sensitive-terms.txt"
ok "allow list created" test -f "$COORD_DATA/public-allow.txt"
ok "tasks folder created" test -d "$COORD_DATA/tasks"
eq "hooks path set" "hooks" "$(G config core.hooksPath)"
eq "the user name is seeded" 1 "$(grep -cxF "$(id -un)" "$COORD_DATA/sensitive-terms.txt")"
ok "asks which folders are company" grep -q '^decide: which folders are company' <<< "$out"
eq "the first decision is the routing row that blocks every launch" \
  "decide: which folders are company: replace the example rows of $COORD_DATA/config/routing.tsv (path, provider, scope); the example folder does not exist, so route.sh refuses every call and nothing can be launched until it is replaced" \
  "$(grep '^decide: ' <<< "$out" | head -1)"
ok "asks for the private terms" grep -q '^decide: the private terms' <<< "$out"
fails 1 "never prints a seeded term" grep -qF "$(id -un)" <<< "$out"
snap() { (cd "$COORD_DATA" && find . -type f | sort | while IFS= read -r f; do cksum "$f"; done); }
out=$($S --check 2>&1); code=$?
eq "check with the example routing row has work to do" 1 "$code"
eq "check names the row route.sh refuses" \
  "routing: $COORD_DATA/config/routing.tsv line 1: the folder '/path/to/company' does not exist; nothing can be launched until that row is fixed" \
  "$(grep '^routing: ' <<< "$out")"
printf '%s\tclaude\tcompany\n*\tcodex\tpersonal\n' "$CO" > "$COORD_DATA/config/routing.tsv"
ok "a usable routing table is not reported" sh -c "! '$S' --check 2>&1 | grep -q '^routing: '"
PATH=/usr/bin:/bin $S >/dev/null 2>&1; before=$(snap); PATH=/usr/bin:/bin $S >/dev/null 2>&1; eq "second run gives the same result" "$before" "$(snap)"
ok "check passes after setup" $S --check
fails 1 "check after setup has nothing to do" grep -q '^would' <<< "$($S --check 2>&1)"
: > "$COORD_DATA/sensitive-terms.txt"; $S >/dev/null 2>&1
eq "an empty term list is seeded" 1 "$(grep -cxF "$(id -un)" "$COORD_DATA/sensitive-terms.txt")"
$S >/dev/null 2>&1
eq "a term already listed is not added twice" 1 "$(grep -cxF "$(id -un)" "$COORD_DATA/sensitive-terms.txt")"
git -C "$PE/app" init -q; git -C "$PE/app" remote add origin git@github.com:acmeco/app.git
git -C "$PE/app" remote add mirror https://git.acme-corp.example/team/app.git
# A word set in place of a push address to disable pushing, and a remote that is a local folder: not addresses.
git -C "$PE/app" remote set-url --push mirror nopushword
git -C "$PE/app" remote add sibling ../sibling.repo
printf '%s\tcodex\tacmewidgets\n' "$PE" >> "$COORD_DATA/config/routing.tsv"; $S >/dev/null 2>&1
has() { grep -qxF "$1" "$COORD_DATA/sensitive-terms.txt"; }
ok "a routed path is seeded" has "$PE"
ok "an unusual scope name is seeded" has acmewidgets
ok "the owner on a public host is seeded" has acmeco
ok "a private remote host is seeded" has git.acme-corp.example
fails 1 "the public host itself is not seeded" has github.com
fails 1 "a push-disabling word is not seeded" has nopushword
fails 1 "a local folder remote is not seeded" sh -c 'grep -qiF sibling "$1"' _ "$COORD_DATA/sensitive-terms.txt"
rm -rf "$COORD_DATA" "$FIX/.gitignore"
fails 1 "refused when the private folder would be tracked" $S
fails 1 "nothing created when refused" test -e "$COORD_DATA"

# Account kinds are never inherited from the example: every seeded row is unknown, and each is asked about.
rm -rf "$COORD_DATA"; printf '.private/\n' > "$FIX/.gitignore"
out=$(PATH=/usr/bin:/bin $S 2>&1)
eq "every seeded kind is unknown" "unknown" "$(awk -F'\t' '!/^#/ && NF {print $2}' "$COORD_DATA/config/providers.tsv" | sort -u)"
eq "the example rows are seeded" "$(awk -F'\t' '!/^#/ && NF {print $1}' "$FIX/config/providers.example.tsv")" \
  "$(awk -F'\t' '!/^#/ && NF {print $1}' "$COORD_DATA/config/providers.tsv" | head -2)"
ok "the decide line names claude and codex" grep -q '^decide: the account kind .*claude, codex' <<< "$out"
printf 'odd\tsomething\t-\t-\t-\t-\n' >> "$COORD_DATA/config/providers.tsv"
ok "a kind that is not valid is asked about" grep -q '^decide: the account kind .*odd' <<< "$(PATH=/usr/bin:/bin $S 2>&1)"
