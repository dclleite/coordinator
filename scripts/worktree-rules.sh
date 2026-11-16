# Sourced by worktree-cleanup.sh and cleanup-pending.sh after lib.sh.
# keep_reason <repo> <worktree> <task-dir>: prints why the worktree must stay and returns 0; returns 1 when
# these rules allow removing it (worktree_removable in lib.sh still checks git's own state).

PROTECTED=$("$SCRIPTS/service.sh" protected paths 2>/dev/null) || PROTECTED=""

protected() {
  local e er p real; real=$(physical "$1")
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case $e in
      *'*') e=${e%\*}; for p in "$1" "$real"; do [ -n "$p" ] && case $p in "$e"*) return 0;; esac; done;;
      *) e=${e%/}; er=$(physical "$e")
         for p in "$1" "$real"; do
           [ -n "$p" ] || continue
           case $p in "$e"|"$e"/*) return 0;; esac
           [ -z "$er" ] || case $p in "$er"|"$er"/*) return 0;; esac
         done;;
    esac
  done <<< "$PROTECTED"
  return 1
}

# A folder the developer made by hand looks the same to git, so only these locations count as the coordinator's.
made_here() {
  local real=$1 repo=$2 root main
  [ -n "$real" ] || return 1
  main=$(cd "$real" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd -P)
  for root in "$(physical "$repo")" "$main"; do
    [ -n "$root" ] || continue
    case $real in "$root"/.claude/worktrees/?*) return 0 ;; esac
  done
  [ -f "$DATA/config/worktree-roots.txt" ] || return 1
  while IFS= read -r root; do
    root=${root%$'\r'}
    case $root in ''|'#'*) continue ;; esac
    root=$(physical "$root"); [ -n "$root" ] || continue
    case $real in "$root"/?*) return 0 ;; esac
  done < "$DATA/config/worktree-roots.txt"
  return 1
}

# Prints the first open task, other than <task-dir>, whose agents.tsv names the same worktree folder.
recorded_elsewhere() {
  local real=$1 self t d line w
  [ -n "$real" ] || return 1
  self=$(physical "${2:-/nonexistent}")
  for t in "$DATA"/tasks/*/*/task.md; do
    [ -f "$t" ] && [ "$(field "$t" status)" = open ] || continue
    d=$(physical "${t%/task.md}")
    [ "$d" != "$self" ] && [ -f "$d/agents.tsv" ] || continue
    while IFS= read -r line; do
      split_row "$line"; w=${F6:-}
      [ -n "$w" ] && [ "$w" != - ] || continue
      if [ "$(physical "$w")" = "$real" ]; then echo "${d#"$(physical "$DATA/tasks")"/}"; return 0; fi
    done < "$d/agents.tsv"
  done
  return 1
}

# made_record <real-path> <task-dir>: prints the id of the task's open "worktrees" resource row for that folder,
# written by the agent that created it. The developer's own worktrees sit in the same folders and have none.
made_record() {
  local real=$1 id
  [ -n "$real" ] && [ -n "${2:-}" ] && [ -f "$2/resources.tsv" ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] && [ "$(physical "$id")" = "$real" ] && { echo "$id"; return 0; }
  done < <(awk -F'\t' '$1=="worktrees" && $5=="-" {print $2}' "$2/resources.tsv")
  return 1
}

keep_reason() {
  local real other
  if protected "$2"; then echo "protected by a service"; return 0; fi
  real=$(physical "$2")
  if [ -n "$real" ] && [ "$real" = "$(physical "$1")" ]; then echo "the main checkout"; return 0; fi
  if other=$(recorded_elsewhere "$real" "$3"); then echo "recorded by another open task: $other"; return 0; fi
  if ! made_record "$real" "$3" >/dev/null; then
    echo "not recorded as made by the coordinator (resource-add.sh <task-dir> worktrees <path>)"; return 0; fi
  if ! made_here "$real" "$1"; then echo "not in a worktrees folder of the coordinator"; return 0; fi
  return 1
}

