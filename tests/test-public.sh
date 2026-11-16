. "$(dirname "$0")/lib.sh"; mktask; P="$ROOT/scripts/public-check.sh"
# Every leak-shaped string is assembled at run time: this file is itself checked before publishing.
at='@'; U=Users
fails 2 "no term list is not vouched for" $P
ok "generic mode needs no term list" $P --generic
: > "$COORD_DATA/sensitive-terms.txt"
echo "plain notes" > "$FIX/notes.md"
ok "clean tree passes with an empty term list" $P
caught() { printf '%s\n' "$2" > "$FIX/leak.md"; fails 1 "caught: $1" $P --generic
  eq "kind named: $1" "leak.md: line 1: $1" "$($P --generic 2>/dev/null | grep '^leak.md' | head -1)"; rm -f "$FIX/leak.md"; }
caught "home path" "see /$U/someone/projects/x"
caught "internal host" "clone from build.acme.""internal/x"
caught "internal host" "open jira"".acme-corp.io/browse"
caught "email address" "write to ops${at}acme-corp.io"
caught "chat id" "ask <${at}U""0ABCDEF12> in the channel"
caught "ticket key" "fixes ZZQ""-42 today"
printf 'fine\nhook https://hooks.slack''.com/services/T0000/B0000/abcdefghij0123456789\n' > "$FIX/leak.md"
eq "chat webhook is a secret" "leak.md: line 2: secret: chat webhook" "$($P --generic 2>/dev/null | grep '^leak.md')"
rm "$FIX/leak.md"
printf 'a\000b\001' > "$FIX/blob.bin"
eq "binary file refused" "blob.bin: binary file" "$($P --generic 2>/dev/null)"
echo "blob.bin" > "$COORD_DATA/public-allow.txt"
ok "binary file let through when its path is allowed" $P
rm "$FIX/blob.bin"; : > "$COORD_DATA/public-allow.txt"
printf 'Ticket ABC-123 in <company-repo>, ACME-77, git%sgithub.com:acme/x.git, host example.invalid, mail dev%sexample.invalid, UTF-8, /home/<you>\n' "$at" "$at" > "$FIX/doc.md"
ok "placeholders pass" $P
printf 'one ops%sacme-corp.io\ntwo dev%sacme-corp.io\n' "$at" "$at" > "$FIX/leak.md"
echo "ops${at}acme-corp.io" > "$COORD_DATA/public-allow.txt"
eq "an allow entry lets exactly one string through" "leak.md: line 2: email address" "$($P 2>/dev/null)"
rm "$FIX/leak.md"; : > "$COORD_DATA/public-allow.txt"
printf '# names\nAcmeCorp\n\ninternal.example\n' > "$COORD_DATA/sensitive-terms.txt"
echo "ticket in ACMECORP tracker" > "$FIX/leak.md"
fails 1 "term found in any case" $P
eq "file, line and kind named, not the text" "leak.md: line 1: private term" "$($P 2>/dev/null)"
ok "generic mode ignores the term list" $P --generic
rm "$FIX/leak.md"; echo "see internal.example/x" > "$COORD_DATA/tasks/record.md"
ok "private folder is not scanned" $P
fails 2 "commits needs a range" $P --commits
# A git repository under the fixture for --commits.
G() { git -C "$FIX" -c user.name=tester -c user.email="tester${at}example.invalid" "$@"; }
G init -q; printf '.private/\n' > "$FIX/.gitignore"; G add -A; G commit -qm "baseline"; first=$(G rev-parse HEAD)
ok "clean history passes" $P --commits HEAD
echo "internal.example notes" > "$FIX/old.md"; G add -A; G commit -qm "add notes"
G rm -q old.md; G commit -qm "remove notes"
ok "tree is clean after the removal" $P
out=$($P --commits HEAD 2>/dev/null)
eq "a file in an earlier commit is caught" "1" "$(printf '%s\n' "$out" | grep -c ':old.md: line 1: private term$')"
base=$(G rev-parse HEAD)
G commit -q --allow-empty -m "talk to AcmeCorp"
eq "commit message caught" "commit $(G rev-parse --short HEAD): line 4: private term" "$($P --commits "$base..HEAD" 2>/dev/null)"
base=$(G rev-parse HEAD)
GIT_AUTHOR_NAME="Acmecorp Bot" G commit -q --allow-empty -m "neutral"
eq "commit author caught" "commit $(G rev-parse --short HEAD): line 1: private term" "$($P --commits "$base..HEAD" 2>/dev/null)"
ok "history before the bad commits passes" $P --commits "$first"

# (a) File names and paths are text too, in both modes.
base=$(G rev-parse HEAD)
mkdir -p "$FIX/notes"; echo "plain" > "$FIX/notes/AcmeCorp-plan.md"; echo "plain" > "$FIX/ZZQ""-9.md"
out=$($P 2>/dev/null)
ok "tree: a private term in a path is caught" grep -qx 'notes/AcmeCorp-plan.md: file name: private term' <<< "$out"
ok "tree: a ticket key in a file name is caught" grep -qx "ZZQ""-9.md: file name: ticket key" <<< "$out"
G add -A; G commit -qm "plans"; s=$(G rev-parse --short HEAD)
out=$($P --commits "$base..HEAD" 2>/dev/null)
ok "commits: a private term in a path is caught" grep -qx "$s:notes/AcmeCorp-plan.md: file name: private term" <<< "$out"
ok "commits: a ticket key in a file name is caught" grep -qx "$s:ZZQ""-9.md: file name: ticket key" <<< "$out"
G rm -rq notes "ZZQ""-9.md"; G commit -qm "drop plans"
ok "tree clean again" $P

# (b) Content that exists only in a merge commit (a conflict resolution) is checked.
base=$(G rev-parse HEAD); trunk=$(G symbolic-ref --short HEAD)
echo "one" > "$FIX/m.md"; G add m.md; G commit -qm "m"
G checkout -qb side; echo "side" > "$FIX/m.md"; G commit -qam "side"
G checkout -q "$trunk"; echo "trunk" > "$FIX/m.md"; G commit -qam "trunk"
G merge -q side >/dev/null 2>&1; printf 'resolved at /%s/someone/x\n' "$U" > "$FIX/m.md"; G add m.md; G commit -qm "merge side"
s=$(G rev-parse --short HEAD)
ok "commits: a merge resolution is checked" grep -qx "$s:m.md: line 1: home path" <<< "$($P --commits "$base..HEAD" 2>/dev/null)"
echo "clean" > "$FIX/m.md"; G commit -qam "clean m"

# (c) The staged version is what a commit takes; a symlink's stored target is text.
ok "staged: clean index passes" $P --staged
printf 'see /%s/someone/x\n' "$U" > "$FIX/m.md"; G add m.md; echo "clean" > "$FIX/m.md"
eq "staged: the staged version is read, not the working file" "m.md: line 1: home path" "$($P --staged 2>/dev/null)"
G add m.md; ln -s "/$U/someone/missing" "$FIX/link"
eq "tree: a symlink's target is checked, even when missing" "link: line 1: home path" "$($P 2>/dev/null)"
G add link
eq "staged: a symlink's stored target is checked" "link: line 1: home path" "$($P --staged 2>/dev/null)"
G rm -q --cached link; rm "$FIX/link"
ok "hook checks the staged version" grep -q -- '--staged' "$ROOT/hooks/pre-commit"

# (d) An entry of the tracked allow file passes only a pattern detector's hit, never a private term or the local
# user or host; the tracked file is itself checked; the staged mode reads its staged version.
TA=$FIX/config/public-allow.txt; cp "$TA" "$_TMPROOT/allow.orig"
printf 'AcmeCorp\nops%sacme-corp.io\n' "$at" >> "$TA"; n=$(grep -c '' "$TA")
echo "AcmeCorp roadmap" > "$FIX/d.md"; echo "mail ops${at}acme-corp.io" > "$FIX/e.md"
out=$($P 2>/dev/null)
ok "tree: a tracked entry does not pass a private term" grep -qx 'd.md: line 1: private term' <<< "$out"
ok "tree: the tracked allow file is checked against the terms" grep -qx "config/public-allow.txt: line $((n - 1)): private term" <<< "$out"
fails 1 "tree: a tracked entry passes a pattern hit" grep -q '^e.md:' <<< "$out"
u=$(id -un 2>/dev/null)
if [ "${#u}" -ge 4 ] && ! grep -qixF "$u" "$COORD_DATA/sensitive-terms.txt"; then
  case $u in root|user|admin|runner|ubuntu|vagrant|localhost) ;; *)
    printf '%s\n' "$u" >> "$TA"; echo "by $u" > "$FIX/u.md"
    ok "tree: a tracked entry does not pass the local user" grep -qx 'u.md: line 1: local user or host' <<< "$($P 2>/dev/null)"
    rm -f "$FIX/u.md" ;;
  esac
fi
echo "AcmeCorp" > "$COORD_DATA/public-allow.txt"
fails 1 "tree: the private allow file still passes a term" grep -q '^d.md:' <<< "$($P 2>/dev/null)"
: > "$COORD_DATA/public-allow.txt"; rm -f "$FIX/d.md"
cp "$_TMPROOT/allow.orig" "$TA"; G add -A
eq "staged: an entry only in the working allow file does not count" "e.md: line 1: email address" "$(printf 'ops%sacme-corp.io\n' "$at" >> "$TA"; $P --staged 2>/dev/null)"
G add "$TA"; cp "$_TMPROOT/allow.orig" "$TA"
ok "staged: the staged allow file counts" $P --staged
cp "$_TMPROOT/allow.orig" "$TA"; printf 'AcmeCorp\n' >> "$TA"; echo "AcmeCorp roadmap" > "$FIX/d.md"; G add -A
fails 1 "staged: a term in a staged allow entry is refused" $P --staged
base=$(G rev-parse HEAD); G commit -qm "allow" --no-verify; s=$(G rev-parse --short HEAD)
out=$($P --commits "$base..HEAD" 2>/dev/null)
ok "commits: the document is caught" grep -qx "$s:d.md: line 1: private term" <<< "$out"
ok "commits: the allow file is caught" grep -q "^$s:config/public-allow.txt: line [0-9]*: private term$" <<< "$out"
G rm -q d.md e.md; cp "$_TMPROOT/allow.orig" "$TA"; G add -A; G commit -qm "undo"

# (e) An annotated tag's message and tagger are checked.
G tag -a v1 -m "release for AcmeCorp" HEAD
out=$($P --tag v1 2>/dev/null)
eq "tag: the message is caught" "tag v1: line 6: private term" "$out"
G -c user.name="Acmecorp Bot" tag -a v2 -m "release" HEAD
ok "tag: the tagger is caught" grep -q '^tag v2: line [0-9]*: private term$' <<< "$($P --tag v2 2>/dev/null)"
G tag -a v3 -m "release" HEAD
ok "tag: a clean tag passes" $P --tag v3
fails 2 "tag: not a tag" $P --tag HEAD
