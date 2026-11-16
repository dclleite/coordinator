#!/bin/bash
# route.sh provider|scope <path> | check <provider> <path> | check-task <provider> <task-dir> | pick <task-dir> [<repo>]
set -u
. "$(dirname "$0")/lib.sh"
ROUTING=$DATA/config/routing.tsv
PROVIDERS=$DATA/config/providers.tsv
SCOPES=$DATA/config/scopes.tsv
[ -f "$ROUTING" ] || die 2 "no routing table: copy config/routing.example.tsv to $ROUTING and set your paths"

# Physical form of a path that may not exist yet: resolve the nearest existing parent.
resolve() {
  local p=${1%/} rest=""
  [ -n "$p" ] || p=/
  while [ ! -d "$p" ]; do
    rest="/$(basename "$p")$rest"; p=$(dirname "$p")
  done
  case "$rest/" in */../*|*/./*) return 1 ;; esac
  echo "$(physical "$p")$rest"
}

# The routing rows, each path in the physical form an input path gets. A row that cannot be trusted
# stops every call: falling through to the "*" default would route a company folder as personal.
load_routes() {
  local line n=0 tabs p real
  ROUTES=""
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" != *$'\r' ]] || die 2 "$ROUTING line $n: ends with CR (Windows line ends): save with LF"
    tabs=${line//[!$'\t']/}
    split_row "$line"
    if [ "${#tabs}" -ne 2 ] || [ -z "$F1" ] || [ -z "$F2" ] || [ -z "$F3" ] || [[ "$line" == *$'\r'* ]]; then
      die 2 "$ROUTING line $n: not three tab-separated fields (path, provider, scope)"
    fi
    if [ "$F1" != "*" ]; then
      p=$F1
      case "$p" in "~") p=${HOME:-} ;; "~/"*) p=${HOME:-}/${p#"~/"} ;; esac
      case "$p" in /*) real=$(physical "$p") ;; *) real="" ;; esac
      [ -n "$real" ] || die 2 "$ROUTING line $n: the folder '$F1' does not exist"
      F1=$real
    fi
    ROUTES=$ROUTES$F1$'\t'$F2$'\t'$F3$'\n'
  done < "$ROUTING"
}
load_routes
routes() { printf '%s' "$ROUTES"; }

# Prints "provider<TAB>scope" for the longest matching prefix.
lookup() {
  # Compared in lower case: the volume is case-insensitive, so /x/Company is /x/company.
  routes | P=$1 awk -F'\t' 'BEGIN { p=tolower(ENVIRON["P"]) }
    $1=="*" { dp=$2; ds=$3; next }
    { pre=tolower($1) }
    p==pre || index(p, pre"/")==1 { if (length($1) > best) { best=length($1); bp=$2; bs=$3 } }
    END { if (best) print bp"\t"bs; else print dp"\t"ds }'
}

# The kind as written in providers.tsv, empty when the provider has no valid one.
stated_kind() {
  [ -f "$PROVIDERS" ] || return 0
  K=$1 awk -F'\t' '$1==ENVIRON["K"] { k=$2; exit } END { if (k=="company" || k=="personal" || k=="local") print k }' "$PROVIDERS"
}
kind_of() { local k; k=$(stated_kind "$1"); echo "${k:-personal}"; }

# Comma list of the kinds a scope accepts; empty accepts nothing.
accepts_of() {
  local row="" routed
  [ -f "$SCOPES" ] && row=$(S=$1 awk -F'\t' '$1==ENVIRON["S"] { print "=" $2; exit }' "$SCOPES")
  if [ -n "$row" ]; then printf '%s\n' "${row#=}" | tr -d ' '; return; fi
  # No row: only the kind of the provider routed to the scope, and only when that kind is stated,
  # so an unconfigured company scope never inherits the personal default.
  routed=$(routes | S=$1 awk -F'\t' '$3==ENVIRON["S"] { print $2; exit }')
  [ -n "$routed" ] || return 0
  stated_kind "$routed"
}

has_kind() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }

intersect() {
  local k out=""
  for k in company personal local; do
    if has_kind "$k" "$1" && has_kind "$k" "$2"; then out=${out:+$out,}$k; fi
  done
  echo "$out"
}

# The coordinator's folders: ROOT, DATA, the main checkout of either and every worktree of it,
# so a script run from a worktree still guards the main checkout and the other worktrees.
coord_bases() {
  local d common main
  printf '%s\n' "$ROOT" "$DATA"
  command -v git >/dev/null 2>&1 || return 0
  for d in "$ROOT" "$DATA"; do
    common=$(cd "$d" 2>/dev/null && common=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$common" && pwd -P) || continue
    [ "$(basename "$common")" = .git ] || continue
    main=$(dirname "$common")
    echo "$main"
    git -C "$main" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
  done
}

inside() {
  local low base
  low=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    base=$(resolve "$base") || continue
    base=$(printf '%s' "${base%/}" | tr 'A-Z' 'a-z')
    case "$low/" in "$base"/*) return 0 ;; esac
  done < <(coord_bases)
  return 1
}

# Scopes that hold at least one task folder.
busy_scopes() {
  local d
  for d in "$DATA"/tasks/*/; do
    [ -d "$d" ] || continue
    set -- "$d"*/task.md
    [ -e "$1" ] && basename "$d"
  done
  return 0
}

refuse_kind() { # <provider> <accepted> <where>
  local kind; kind=$(kind_of "$1")
  has_kind "$kind" "$2" || die 1 "refused: $1 ($kind account) must not run for $3 (accepts: ${2:-nothing})"
}

check_path() {
  local real row scope acc s
  real=$(resolve "$2") || die 1 "refused: cannot resolve '$2'"
  row=$(lookup "$real"); scope=${row##*	}
  acc=$(accepts_of "$scope")
  if inside "$real"; then
    for s in $(busy_scopes); do acc=$(intersect "$acc" "$(accepts_of "$s")"); done
    refuse_kind "$1" "$acc" "the coordinator's folder $real while records of its scopes exist"
  else
    refuse_kind "$1" "$acc" "$real ($scope scope)"
  fi
}

task_scope() {
  local s
  task_dir "$1"
  s=$(field "$1/task.md" scope)
  [ -n "$s" ] || die 2 "task.md has no scope: $1"
  echo "$s"
}

# The paths named in the task's repositories: field, a comma-separated list; words that are not paths are names.
task_repos() {
  local list piece w words
  list=$(field "$1/task.md" repositories)
  while IFS= read -r piece; do
    piece=$(printf '%s' "$piece" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$piece" in /*) if [ -e "$piece" ]; then echo "$piece"; continue; fi ;; esac
    read -r -a words <<< "$piece"
    for w in ${words[@]+"${words[@]}"}; do
      w=$(printf '%s' "$w" | sed "s/^[(<\[\"']*//; s/[]):;,.>\"']*\$//")
      case "$w" in /*|"~"|"~/"*) echo "$w" ;; esac
    done
  done < <(printf '%s\n' "$list" | tr ',' '\n')
}

check_task() {
  local s r real row sc
  s=$(task_scope "$2") || exit $?
  refuse_kind "$1" "$(accepts_of "$s")" "a $s task"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in "~") r=${HOME:-} ;; "~/"*) r=${HOME:-}/${r#"~/"} ;; esac
    real=$(resolve "$r") || die 1 "refused: cannot resolve '$r', a repository of the task"
    row=$(lookup "$real"); sc=${row##*	}
    refuse_kind "$1" "$(accepts_of "$sc")" "$real ($sc scope), a repository of the task"
  done < <(task_repos "$2")
}

passes() { (check_path "$1" "$2") 2>/dev/null && (check_task "$1" "$3") 2>/dev/null; }

pick() {
  local dir=$1 repo=${2:-} s p real
  s=$(task_scope "$dir") || exit $?
  if [ -n "$repo" ] && real=$(resolve "$repo"); then
    p=$(lookup "$real"); p=${p%%	*}
    if [ -n "$p" ] && passes "$p" "$repo" "$dir"; then echo "$p"; return; fi
  fi
  p=$(routes | S=$s awk -F'\t' '$3==ENVIRON["S"] { print $2; exit }')
  if [ -n "$p" ] && passes "$p" "$ROOT" "$dir"; then echo "$p"; return; fi
  if [ -f "$PROVIDERS" ]; then
    for p in $(awk -F'\t' '$1!="" && $1!~/^#/ { print $1 }' "$PROVIDERS"); do
      if passes "$p" "$ROOT" "$dir"; then echo "$p"; return; fi
    done
  fi
  die 1 "no provider may run a $s task from the coordinator's folder: set account kinds in $PROVIDERS and $SCOPES"
}

cmd=${1:-}
usage="usage: route.sh provider|scope <path> | check <provider> <path> | check-task <provider> <task-dir> | pick <task-dir> [<repo>]"
case "$cmd" in
  provider|scope)
    [ $# -eq 2 ] && [ -n "$2" ] || die 2 "usage: route.sh $cmd <path>"
    real=$(resolve "$2") || die 1 "cannot resolve '$2': '..' through a folder that does not exist"
    row=$(lookup "$real")
    if [ "$cmd" = provider ]; then echo "${row%%	*}"; else echo "${row##*	}"; fi ;;
  check)
    [ $# -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || die 2 "usage: route.sh check <provider> <path>"
    check_path "$2" "$3" ;;
  check-task)
    [ $# -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || die 2 "usage: route.sh check-task <provider> <task-dir>"
    check_task "$2" "$3" ;;
  pick)
    [ $# -ge 2 ] && [ $# -le 3 ] && [ -n "$2" ] || die 2 "usage: route.sh pick <task-dir> [<repo>]"
    pick "$2" "${3:-}" ;;
  *) die 2 "$usage" ;;
esac
