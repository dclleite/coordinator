#!/bin/bash
# public-check.sh [--generic] [--staged | --tag <tag> | --commits <rev-list arguments>...]
#   exit 0 only when nothing git would publish leaks private data; prints "<where>: line <n>: <kind>" per hit, never the text.
#   File names and paths are checked as text, and so is a symlink's target.
#   --generic   pattern detectors only: no private term list, no local user or host (what CI can run)
#   --staged    check what the index holds instead of the working files (the pre-commit hook)
#   --commits   check the messages, authors and committers of those commits and every file they add or change,
#               merge commits included
#   --tag       check an annotated tag's message and tagger (the pre-push hook, for each tag it sends)
set -u
. "$(dirname "$0")/lib.sh"
generic=0; commits=0; staged=0; tag=""
USAGE="usage: public-check.sh [--generic] [--staged | --tag <tag> | --commits <range>]"
while [ $# -gt 0 ]; do
  case $1 in
    --generic) generic=1; shift ;;
    --staged) staged=1; shift ;;
    --tag) [ $# -ge 2 ] && [ -n "$2" ] || die 2 "$USAGE"; tag=$2; shift 2 ;;
    --commits) commits=1; shift; break ;;
    *) die 2 "$USAGE" ;;
  esac
done
[ "$commits" -eq 0 ] || [ $# -gt 0 ] || die 2 "$USAGE"
modes=$((commits + staged)); [ -z "$tag" ] || modes=$((modes + 1))
[ "$modes" -le 1 ] || die 2 "$USAGE"
export LC_ALL=C

W=$(mktemp -d "${TMPDIR:-/tmp}/public-check.XXXXXX") || die 2 "cannot create a temporary folder"
trap 'rm -rf "$W"' EXIT
: > "$W/terms"; : > "$W/ident"; : > "$W/allow"; : > "$W/allowt"; : > "$W/report"; : > "$W/names"; : > "$W/labels"; : > "$W/seen"

clean_list() { [ -f "$1" ] && tr -d '\r' < "$1" | grep -v -e '^#' -e '^[[:space:]]*$'; }
if [ "$generic" -eq 0 ]; then
  # Fails closed: a machine that never ran setup has not said what is private.
  [ -f "$DATA/sensitive-terms.txt" ] || die 2 "no term list at $DATA/sensitive-terms.txt: run scripts/setup.sh"
  clean_list "$DATA/sensitive-terms.txt" > "$W/terms"
  [ -n "${HOME:-}" ] && [ "$HOME" != / ] && printf '%s\n' "$HOME" >> "$W/terms"
  # Names this short or this common would flag ordinary words; a CI runner is called "runner".
  for n in "$(id -un 2>/dev/null)" "$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)"; do
    [ "${#n}" -ge 4 ] || continue
    case $n in root|user|admin|runner|ubuntu|vagrant|localhost) continue ;; esac
    printf '%s\n' "$n" >> "$W/ident"
  done
fi
# The tracked list is public and anyone can edit it, so it never passes a private term or the local user or host.
# The staged mode reads the version the commit would take.
if [ "$staged" -eq 1 ]; then
  git -C "$ROOT" show :config/public-allow.txt > "$W/allowt.raw" 2>/dev/null || : > "$W/allowt.raw"
  clean_list "$W/allowt.raw" >> "$W/allowt"
else
  clean_list "$ROOT/config/public-allow.txt" >> "$W/allowt"
fi
clean_list "$DATA/public-allow.txt" >> "$W/allow"

B='(^|[^A-Za-z0-9_])'; E='([^A-Za-z0-9_]|$)'
DETECTORS="home path	(^|[^A-Za-z0-9._-])/(Users|home)/[A-Za-z0-9._-]+
home path	[A-Za-z]:\\\\Users\\\\[A-Za-z0-9._-]+
email address	[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}
internal host	[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.(internal|corp|lan|intranet|local|localdomain)([^A-Za-z0-9.-]|\\.[[:space:]]|\\.\$|\$)
internal host	(^|[^A-Za-z0-9.-])(git|gitlab|code|jira|confluence|wiki|intranet|vpn|jenkins|grafana|kibana|sentry|vault|artifactory|nexus)\\.[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}
internal host	[A-Za-z0-9-]+\\.(atlassian\\.net|slack\\.com|sharepoint\\.com|zendesk\\.com|service-now\\.com|okta\\.com)
internal host	${B}(10\\.[0-9]{1,3}|192\\.168|172\\.(1[6-9]|2[0-9]|3[01]))\\.[0-9]{1,3}\\.[0-9]{1,3}${E}
chat id	(^|[^A-Za-z0-9])[CDGTUW][0-9][A-Z0-9]{7,10}([^A-Za-z0-9]|\$)
chat id	(^|[^A-Za-z0-9])p[0-9]{16}([^0-9]|\$)
ticket key	(^|[^A-Za-z0-9_-])[A-Z][A-Z0-9]{1,9}-[0-9]+${E}"

# check_file <file> <name shown in the report>
check_file() {
  local f=$1 name=$2 kind re n rest
  [ -s "$f" ] || return 0
  if ! grep -qI '' "$f" 2>/dev/null; then
    grep -qxF -e "$name" "$W/allow" "$W/allowt" || printf '%s: binary file\n' "$name" >> "$W/report"
    return 0
  fi
  : > "$W/hits"
  while IFS='	' read -r kind re; do
    grep -noE -e "$re" "$f" 2>/dev/null | sed "s/:/	$kind	/" >> "$W/hits"
  done <<< "$DETECTORS"
  [ -s "$W/terms" ] && grep -noiF -f "$W/terms" "$f" 2>/dev/null | sed 's/:/	private term	/' >> "$W/hits"
  [ -s "$W/ident" ] && grep -noiwF -f "$W/ident" "$f" 2>/dev/null | sed 's/:/	local user or host	/' >> "$W/hits"
  # secret-scan.sh never prints the text, so an allow entry is matched against the whole line instead.
  bash "$SCRIPTS/secret-scan.sh" "$f" 2>/dev/null | while IFS= read -r rest; do
    n=${rest#line }; n=${n%%:*}; kind=${rest#*: }
    printf '%s\tsecret: %s\t%s\n' "$n" "$kind" "$(sed -n "${n}p" "$f")"
  done >> "$W/hits"
  [ -s "$W/hits" ] || return 0
  awk -F'\t' -v name="$name" -v allowf="$W/allow" -v allowtf="$W/allowt" '
    BEGIN { while ((getline a < allowf) > 0) { allow[a] = 1; if (length(a) >= 8) long[++nl] = a }
      while ((getline a < allowtf) > 0) { pattern[a] = 1; if (length(a) >= 8) long[++nl] = a } }
    function trim(m, k) { if (k == "home path") sub(/^[^A-Za-z0-9\/]+/, "", m); else sub(/^[^A-Za-z0-9]+/, "", m); while (m ~ /[^A-Za-z0-9]$/) sub(/.$/, "", m); return m }
    function example_host(h) { return h ~ /(^|\.)(example(\.(invalid|com|org|net))?|invalid|test|localhost)$/ }
    function public_host(h) { return h ~ /(^|\.)(github\.com|gitlab\.com|claude\.com|anthropic\.com|openai\.com|visualstudio\.com|microsoft\.com|google\.com)$/ || h ~ /^(www|api|app|status|docs|hooks)\.slack\.com$/ }
    {
      line = $1; kind = $2; m = $0; sub(/^[^\t]*\t[^\t]*\t/, "", m)
      if (kind ~ /^secret: /) { for (i = 1; i <= nl; i++) if (index(m, long[i])) next }
      else {
        mine = (kind == "private term" || kind == "local user or host")
        if (!mine) m = trim(m, kind)
        if ((m in allow) || (!mine && (m in pattern))) next
        if (kind == "email address") { dom = tolower(substr(m, index(m, "@") + 1)); loc = tolower(substr(m, 1, index(m, "@") - 1))
          if (example_host(dom) || loc == "noreply" || dom ~ /(^|\.)noreply\.github\.com$/ || (loc == "git" && public_host(dom))) next }
        if (kind == "internal host") { h = tolower(m); if (example_host(h) || public_host(h)) next }
        if (kind == "ticket key") { p = m; sub(/-.*/, "", p); if (p ~ /^(ABC|ACME|KEY|UTF|SHA|ISO|RFC|CVE|MD|AES|TLS|SSL|HTTP|IPV)$/) next }
        if (kind == "home path") { u = m; sub(/.*[\/\\]/, "", u); if (u ~ /^(Shared|you|user|username|name|example)$/) next }
      }
      print name ": line " line ": " kind
    }' "$W/hits" | sort -u >> "$W/report"
}

# name <label> <path>: queues a path for the file-name check, reported under <label>.
name() { printf '%s\n' "$2" | tr -d '\n' >> "$W/names"; echo >> "$W/names"; printf '%s\n' "$1" >> "$W/labels"; }
# blob <sha> <label>: checks one stored version (a symlink's blob is its target) once per run.
blob() {
  grep -qxF "$1 $2" "$W/seen" && return 0
  printf '%s %s\n' "$1" "$2" >> "$W/seen"
  git -C "$ROOT" cat-file blob "$1" > "$W/blob" 2>/dev/null || return 0
  check_file "$W/blob" "$2"; checked=$((checked+1))
}

checked=0
if [ -n "$tag" ]; then
  t=$(git -C "$ROOT" rev-parse --verify -q "$tag^{tag}" 2>/dev/null) || die 2 "not an annotated tag: $tag"
  # A tag of a tag: every object in the chain carries its own message and tagger.
  while [ "$(git -C "$ROOT" cat-file -t "$t" 2>/dev/null)" = tag ]; do
    git -C "$ROOT" cat-file tag "$t" > "$W/tag"
    check_file "$W/tag" "tag $tag"; checked=$((checked+1))
    t=$(sed -n 's/^object //p' "$W/tag" | head -1)
  done
  what="$checked tag object(s)"
elif [ "$commits" -eq 1 ]; then
  revs=$(git -C "$ROOT" rev-list "$@") || die 2 "not a commit range: $*"
  for c in $revs; do
    s=$(git -C "$ROOT" rev-parse --short "$c")
    git -C "$ROOT" log -1 --format='author: %an <%ae>%ncommitter: %cn <%ce>%n%n%B' "$c" > "$W/commit"
    check_file "$W/commit" "commit $s"
    # -m diffs a merge against each parent, so a conflict resolution is seen too.
    git -C "$ROOT" diff-tree -m -r -z --root --no-commit-id --diff-filter=ACMRT "$c" > "$W/tree"
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
      set -- $meta
      [ "$2" = 160000 ] && continue
      grep -qxF "$s:$path" "$W/labels" || name "$s:$path" "$path"
      blob "$4" "$s:$path"
    done < "$W/tree"
  done
  what="$(printf '%s\n' "$revs" | grep -c .) commit(s), $checked file version(s)"
elif [ "$staged" -eq 1 ]; then
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die 2 "--staged needs a git repository"
  git -C "$ROOT" ls-files -s -z > "$W/index"
  while IFS= read -r -d '' ent; do
    meta=${ent%%$'\t'*}; path=${ent#*$'\t'}
    set -- $meta
    [ "$1" = 160000 ] && continue
    grep -qxF "$path" "$W/labels" || name "$path" "$path"
    blob "$2" "$path"
  done < "$W/index"
  what="$checked staged file(s)"
else
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    files=$(git -C "$ROOT" ls-files -co --exclude-standard)
  else
    files=$(cd "$ROOT" && find . \( -type f -o -type l \) -not -path './.private/*' -not -path './.git/*' | sed 's|^\./||')
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -L "$ROOT/$f" ]; then
      readlink "$ROOT/$f" > "$W/blob" 2>/dev/null || continue
      name "$f" "$f"; check_file "$W/blob" "$f"; checked=$((checked+1)); continue
    fi
    [ -f "$ROOT/$f" ] || continue
    name "$f" "$f"; check_file "$ROOT/$f" "$f"; checked=$((checked+1))
  done <<< "$files"
  what="$checked files"
fi
# Names are checked in one pass; each hit line maps back to the path it came from.
if [ -s "$W/names" ]; then
  mv "$W/report" "$W/report.files"; : > "$W/report"
  check_file "$W/names" "names"
  awk -v labels="$W/labels" 'BEGIN { while ((getline l < labels) > 0) lab[++n] = l }
    { n = $3; sub(/:$/, "", n); k = $0; sub(/^names: line [0-9]+: /, "", k); print lab[n] ": file name: " k }' \
    "$W/report" > "$W/report.names"
  cat "$W/report.files" "$W/report.names" > "$W/report"
fi
if [ -s "$W/report" ]; then
  cat "$W/report"
  die 1 "not publishable: $(grep -c . "$W/report") hit(s) in $what"
fi
echo "clean: $what"
