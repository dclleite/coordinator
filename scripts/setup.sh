#!/bin/bash
# setup.sh [--check]  ->  makes a fresh clone usable; safe to run again. --check changes nothing and reports.
# Ends with "decide:" lines: what only a person can settle. Exit 1 when a required tool is missing
# or the private folder would be tracked; with --check, also when something is still to be done.
set -u
. "$(dirname "$0")/lib.sh"
check=0
case ${1:-} in --check) check=1 ;; "") ;; *) die 2 "usage: setup.sh [--check]" ;; esac
[ $# -le 1 ] || die 2 "usage: setup.sh [--check]"
failed=0; todo=0
say() { printf '%s\n' "$*"; }
decide() { printf 'decide: %s\n' "$*" >> "$W/decide"; }
W=$(mktemp -d "${TMPDIR:-/tmp}/setup.XXXXXX") || die 2 "cannot create a temporary folder"
trap 'rm -rf "$W"' EXIT
: > "$W/decide"

# 1. Tools.
for t in bash git awk sed grep find mktemp; do
  command -v "$t" >/dev/null 2>&1 && continue
  say "missing (required): $t"; failed=1
done
if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then :; else
  say "missing (required): shasum or sha256sum"; failed=1; fi
opt=""
for t in docker t3 dev-browser; do command -v "$t" >/dev/null 2>&1 || opt="$opt $t"; done
[ -z "$opt" ] || say "not installed (optional):$opt"

# 2. The private folder must never be tracked.
is_git=0; git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && is_git=1
case "$DATA/" in
  "$ROOT"/*)
    rel=${DATA#"$ROOT"/}
    if [ "$is_git" -eq 1 ] && ! git -C "$ROOT" check-ignore -q -- "$rel/probe"; then
      say "refused: $rel is not ignored by git; add it to .gitignore first"; exit 1
    fi ;;
esac

# 3. The skeleton.
mk() { # mk <path> <dir|file> [<source file>]
  [ -e "$1" ] && return 0
  if [ "$check" -eq 1 ]; then say "would create: $1"; todo=1; return 0; fi
  case $2 in
    dir) mkdir -p "$1" ;;
    file) mkdir -p "$(dirname "$1")"; if [ -n "${3:-}" ]; then cp "$3" "$1"; else : > "$1"; fi ;;
  esac
  say "created: $1"
}
for d in "$DATA" "$DATA/config" "$DATA/tasks" "$DATA/services"; do mk "$d" dir; done
# Only a person sets an account kind: the providers example is copied with every kind unknown.
awk -F'\t' -v OFS='\t' '!/^#/ && NF >= 2 { $2 = "unknown" } { print }' "$ROOT/config/providers.example.tsv" \
  > "$W/providers" 2>/dev/null || : > "$W/providers"
for ex in "$ROOT"/config/*.example.tsv; do
  [ -f "$ex" ] || continue
  name=$(basename "$ex" .example.tsv)
  if [ "$name" = providers ]; then mk "$DATA/config/$name.tsv" file "$W/providers"
  else mk "$DATA/config/$name.tsv" file "$ex"; fi
done
printf '%s\n' "# One private term per line: company, people, repositories, hosts, ticket prefixes." \
  "# public-check.sh refuses any tracked file or outgoing commit that contains one, in any case." > "$W/terms-head"
printf '%s\n' "# Exact strings public-check.sh lets through on this machine (one per line)." \
  "# A binary file passes when its path is listed here." > "$W/allow-head"
mk "$DATA/sensitive-terms.txt" file "$W/terms-head"
mk "$DATA/public-allow.txt" file "$W/allow-head"

# 4. Git hooks.
if [ "$is_git" -eq 1 ]; then
  if [ "$(git -C "$ROOT" config core.hooksPath 2>/dev/null)" = hooks ]; then :
  elif [ "$check" -eq 1 ]; then say "would set: git hooks path"; todo=1
  elif git -C "$ROOT" config core.hooksPath hooks 2>/dev/null; then say "set: git hooks path"
  else decide "the git config could not be written from here; run: git -C \"$ROOT\" config core.hooksPath hooks"; fi
else
  say "not a git repository: hooks skipped"
fi

# 5. Seed the private term list with what this machine can tell.
add() { [ "${#1}" -ge 3 ] && printf '%s\n' "$1" >> "$W/cand"; return 0; }
: > "$W/cand"
u=$(id -un 2>/dev/null); add "$u"
if [ "$(uname -s)" = Darwin ]; then add "$(id -F 2>/dev/null)"
else add "$(getent passwd "$u" 2>/dev/null | cut -d: -f5 | cut -d, -f1)"; fi
add "$(hostname 2>/dev/null)"; add "$(hostname -s 2>/dev/null)"
[ -n "${HOME:-}" ] && [ "$HOME" != / ] && add "$HOME"
add "$(git config --global user.name 2>/dev/null)"; add "$(git config --global user.email 2>/dev/null)"
# Prints the host of a remote URL, or the owner after a public host. Nothing for what is not an address:
# a local folder, or a word set in place of a push address to disable pushing.
host_of() {
  printf '%s\n' "$1" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#:[0-9]*/#/#; s#:#/#' |
    awk -F/ '$1 ~ /^(github\.com|gitlab\.com|bitbucket\.org)$/ { if ($2 != "") print $2; next }
      $1 ~ /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/ { print $1 }'
}
routing=$DATA/config/routing.tsv
if [ -f "$routing" ]; then
  while IFS='	' read -r p _ scope; do
    case $p in ""|"#"*|"*"|/path/to/*) ;; *)
      add "$p"
      b=$(basename "$p")
      case $b in work|projects|code|src|dev|repos|git) ;; *) add "$b" ;; esac
      if [ -d "$p" ]; then
        find "$p" -maxdepth 3 -name .git 2>/dev/null | while IFS= read -r g; do
          git -C "$(dirname "$g")" remote -v 2>/dev/null | awk '{print $2}' | sort -u | while IFS= read -r url; do
            add "$(host_of "$url")"; done
        done
      fi ;;
    esac
    case $scope in ""|company|personal|local) ;; *) add "$scope" ;; esac
  done < "$routing"
fi
terms=$DATA/sensitive-terms.txt
[ -f "$terms" ] && cp "$terms" "$W/known" || : > "$W/known"
new=$(awk -v known="$W/known" 'BEGIN { while ((getline k < known) > 0) if (k !~ /^#/) seen[tolower(k)] = 1 }
  !($0 == "" || (tolower($0) in seen)) { seen[tolower($0)] = 1; print }' "$W/cand")
count=$(printf '%s' "$new" | grep -c . || true)
if [ "$count" -eq 0 ]; then :
elif [ "$check" -eq 1 ]; then say "would add: $count discovered term(s) to the private term list"; todo=1
else printf '%s\n' "$new" >> "$terms"; say "added: $count discovered term(s) to the private term list (not printed)"; fi

# 6. Providers.
if [ -x "$SCRIPTS/providers.sh" ]; then
  if [ "$check" -eq 1 ]; then "$SCRIPTS/providers.sh" detect >/dev/null 2>&1 || say "providers.sh detect failed"
  else "$SCRIPTS/providers.sh" detect --write >/dev/null 2>&1 && say "providers: detected" || say "providers.sh detect --write failed"; fi
else
  say "providers.sh not present: providers not detected"
fi

# 7. A routing table route.sh refuses stops every launch.
if [ -f "$routing" ]; then
  why=$("$SCRIPTS/route.sh" scope / 2>&1 >/dev/null); rc=$?
  if [ "$rc" -eq 2 ]; then say "routing: $(printf '%s\n' "$why" | head -1); nothing can be launched until that row is fixed"; todo=1; fi
fi

# 8. What only a person decides.
if [ -f "$routing" ] && grep -q '^/path/to/' "$routing"; then
  decide "which folders are company: replace the example rows of $routing (path, provider, scope); the example folder does not exist, so route.sh refuses every call and nothing can be launched until it is replaced"
elif [ ! -f "$routing" ]; then
  decide "which folders are company: write $routing (path, provider, scope; one \"*\" row is the default)"
fi
prov=$DATA/config/providers.tsv
if [ -f "$prov" ]; then
  unknown=$(awk -F'\t' '$1 != "" && $1 !~ /^#/ && $2 != "company" && $2 != "personal" && $2 != "local" { printf "%s%s", sep, $1; sep = ", " }' "$prov")
  [ -z "$unknown" ] || decide "the account kind (company, personal or local) of: $unknown, in $prov"
else
  decide "which providers you use and the account each is signed in with: write $prov"
fi
decide "the private terms setup cannot discover (company, people, repositories, ticket prefixes): add them to $terms"

cat "$W/decide"
[ "$failed" -eq 0 ] || exit 1
[ "$check" -eq 0 ] || [ "$todo" -eq 0 ] || exit 1
exit 0
