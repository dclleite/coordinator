#!/bin/bash
# dispatch.sh new <scope> <KEY|-> <slug> "<title>" [--fast] [--repo <path>] [--context <file>] [--tier <tier>] < message
# dispatch.sh add <task-dir> [--to <addressee>] [--question "<text>"] [--context <file>] < message
# dispatch.sh launched <task-dir> <thread-id>
# dispatch.sh tasks [<text>]
# dispatch.sh launch <task-dir>
set -u
. "$(dirname "$0")/lib.sh"
# COORD_TOOLS is where the optional machine scripts are looked up (tests point it at fakes).
TOOLS=${COORD_TOOLS:-$SCRIPTS}
usage="usage: dispatch.sh new <scope> <KEY|-> <slug> <title> [--fast] [--repo <path>] [--context <file>] [--tier <tier>] < message
       dispatch.sh add <task-dir> [--to <addressee>] [--question <text>] [--context <file>] < message
       dispatch.sh launched <task-dir> <thread-id>
       dispatch.sh tasks [<text>]
       dispatch.sh launch <task-dir>"

name_of() { local k; k=$(field "$1/task.md" key); if [ -n "$k" ] && [ "$k" != "-" ]; then echo "$k"; else basename "$1"; fi; }

# Sets SUB_THREAD, SUB_PROVIDER, SUB_MODEL, SUB_EFFORT from the task's last usable sub-coordinator row.
sub_row() {
  local line
  SUB_THREAD="" SUB_PROVIDER="" SUB_MODEL="" SUB_EFFORT=""
  [ -f "$1/agents.tsv" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    agent_row "$line"
    [ "$F1" = sub-coordinator ] || continue
    case "$F11" in failed|stopped) continue ;; esac
    SUB_THREAD=$F8 SUB_PROVIDER=$F2 SUB_MODEL=$F3 SUB_EFFORT=$F4
  done < "$1/agents.tsv"
}

healthy() {
  local out code
  [ -x "$TOOLS/health.sh" ] || die 2 "no health check: $TOOLS/health.sh"
  out=$("$TOOLS/health.sh" 2>/dev/null); code=$?
  [ "$code" -eq 0 ] && return 0
  echo "health=$(printf '%s\n' "$out" | tail -1)"
  die 1 "launch nothing: the machine check failed (exit $code)"
}

# fill <role-file> <task> <task-dir>: the role text with its placeholders filled; [task] last, so a title is never re-read.
fill() {
  TASK=$2 TDIR=$3 CPATH=$ROOT awk 'function rep(s, a, b,   i, o) {
      o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
    { l = rep($0, "[task-dir]", ENVIRON["TDIR"]); l = rep(l, "[coordinator path]", ENVIRON["CPATH"])
      print rep(l, "[task]", ENVIRON["TASK"]) }' "$1"
}

# A brief number taken with an exclusive create, so two dispatches never write the same file.
claim_brief() {
  local d=$1/briefs last n
  mkdir -p "$d"
  last=$(ls -a "$d" | sed -n -e 's/^\([0-9][0-9]*\)-.*/\1/p' -e 's/^\.claim-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)
  n=$(( 10#${last:-0} + 1 ))
  until ( set -C; : > "$d/.claim-$(printf '%02d' "$n")" ) 2>/dev/null; do n=$((n + 1)); done
  printf '%02d' "$n"
}

# pick_provider <task-dir> [<repo>]: the agent always runs in the coordinator's folder, so that must pass too.
pick_provider() {
  local p
  p=$("$SCRIPTS/route.sh" pick "$@") || return 1
  if [ $# -ge 2 ] && ! "$SCRIPTS/route.sh" check "$p" "$ROOT" 2>/dev/null; then
    p=$("$SCRIPTS/route.sh" pick "$1") || return 1
  fi
  echo "$p"
}

provider_col() {
  local v=""
  [ -f "$DATA/config/providers.tsv" ] && v=$(P=$1 awk -F'\t' -v n="$2" '$1==ENVIRON["P"] { print $n; exit }' "$DATA/config/providers.tsv")
  echo "${v:--}"
}

# prepare <task-dir> <role> <provider> <model> <effort> <send_to> <context-file|"">: builds, checks and stores the brief.
prepare() {
  local dir=$1 role=$2 provider=$3 model=$4 effort=$5 send=$6 extra=$7 rolefile name nn brief ctx title msg
  case "$role" in sub-coordinator) rolefile=$ROOT/roles/sub-coordinator.md ;; *) rolefile=$ROOT/roles/fast-worker.md ;; esac
  [ -f "$rolefile" ] || die 2 "role file not found: $rolefile"
  name=$(name_of "$dir")
  ctx=$(mktemp "$dir/.dispatch-context.XXXXXX") || die 1 "cannot write in $dir"
  CLEAN+=("$ctx")
  { fill "$rolefile" "$name: $(field "$dir/task.md" title)" "$dir"; [ -z "$extra" ] || { echo; cat "$extra"; }; } > "$ctx"
  nn=$(claim_brief "$dir")
  if [ "$role" = sub-coordinator ]; then brief=$dir/briefs/$nn-sub-coordinator.md; else brief=$dir/briefs/$nn-fast-worker.md; fi
  "$SCRIPTS/brief-build.sh" --for "$provider" "$dir" "$ctx" > "$brief" || { rm -f "$brief"; die 1 "brief not built"; }
  "$SCRIPTS/brief-check.sh" "$dir" "$brief" || { rm -f "$brief"; die 1 "brief does not verify: nothing to send"; }
  title="$name · $role · $(basename "$ROOT")"
  msg="Your brief is the file $brief. Read it whole before anything else, run $ROOT/scripts/brief-check.sh $dir $brief and stop if it fails, then do what it says."
  local tmp; tmp=$(mktemp "$dir/.dispatch.XXXXXX") || die 1 "cannot write in $dir"
  printf 'role=%s\nprovider=%s\nmodel=%s\neffort=%s\nbrief=%s\nsend_to=%s\n' \
    "$role" "$provider" "$model" "$effort" "$brief" "$send" > "$tmp" && mv "$tmp" "$dir/.dispatch"
  printf 'task_dir=%s\nbrief=%s\nrole=%s\nprovider=%s\ninstance=%s\nmodel=%s\neffort_option=%s\neffort=%s\ntitle=%s\nmessage=%s\n' \
    "$dir" "$brief" "$role" "$provider" "$(provider_col "$provider" 3)" "$model" "$(provider_col "$provider" 4)" \
    "$effort" "$title" "$msg"
  [ -z "$send" ] || echo "send_to=$send"
}

# stop_refused <new-task-dir>: names every running agent of an open task that its folder now refuses
# (a personal account in the coordinator's folder once company records exist), in output and ledger.
stop_refused() {
  local t d line
  for t in "$DATA"/tasks/*/*/task.md; do
    [ -f "$t" ] && [ "$(field "$t" status)" = open ] || continue
    d=$(dirname "$t"); [ -f "$d/agents.tsv" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      agent_row "$line"
      [ "$F11" = running ] && [ -n "$F5" ] && [ "$F5" != - ] || continue
      "$SCRIPTS/route.sh" check "$F2" "$F5" >/dev/null 2>&1 && continue
      echo "stop_thread=$F8"
      "$SCRIPTS/ledger.sh" "$1" decision "stop $F1 $F2 thread $F8 of $(name_of "$d"): $F5 now refuses its account" || exit $?
    done < "$d/agents.tsv"
  done
}

model_of() { # <provider> <tier>: sets MODEL and EFFORT
  local r; r=$("$SCRIPTS/model.sh" "$1" "$2") || exit $?
  MODEL=${r%%	*} EFFORT=${r#*	}
}

read_message() {
  mkdir -p "$DATA" || die 1 "cannot write in $DATA"
  MSG=$(mktemp "$DATA/.dispatch-message.XXXXXX") || die 1 "cannot write in $DATA"
  CLEAN+=("$MSG")
  cat > "$MSG"
  [ -s "$MSG" ] || die 2 "empty message"
}

prepared() { [ -f "$1/.dispatch" ] || die 1 "nothing prepared for $1: run dispatch.sh new or add first"; }
get() { sed -n "s/^$1=//p" "$dir/.dispatch" | head -1; }

# record <task-dir> <thread>: the agent row (or the steer of an existing one), the ledger line and the board.
record() {
  local dir=$1 thread=$2 role send brief
  role=$(get role) send=$(get send_to) brief=$(get brief)
  if [ -n "$send" ]; then
    [ "$thread" = "$send" ] || die 1 "prepared for thread $send, not $thread"
    "$SCRIPTS/agent-set.sh" "$dir" "$thread" state running || exit $?
    "$SCRIPTS/ledger.sh" "$dir" steer "new message sent to $role $thread: $(basename "$brief")" || exit $?
  else
    "$SCRIPTS/agent-add.sh" "$dir" "$role" "$(get provider)" "$(get model)" "$(get effort)" "$ROOT" - - "$thread" - || exit $?
    "$SCRIPTS/ledger.sh" "$dir" launch "$role $(get provider) $(get model) $(get effort) in $(basename "$ROOT") thread $thread: $(basename "$brief")" || exit $?
  fi
  rm -f "$dir/.dispatch"
  "$SCRIPTS/board.sh" >/dev/null 2>&1 || echo "board=not rebuilt"
}

CLEAN=() NEWDIR="" COMPLETE=0
cleanup() {
  local f
  for f in ${CLEAN[@]+"${CLEAN[@]}"}; do rm -f "$f"; done
  # A failed "new" leaves no half-made task: the message is still in the caller's hands.
  if [ "$COMPLETE" != 1 ] && [ -n "$NEWDIR" ]; then
    case "$NEWDIR" in "$DATA"/tasks/*/*) rm -rf "$NEWDIR" ;; esac
  fi
}
trap cleanup EXIT

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  new)
    [ $# -ge 4 ] || die 2 "$usage"
    scope=$1 key=$2 slug=$3 title=$4; shift 4
    fast=0 repo="" ctx="" tier=default
    while [ $# -gt 0 ]; do
      case "$1" in
        --fast) fast=1; shift ;;
        --repo|--context|--tier)
          [ $# -ge 2 ] && [ -n "$2" ] || die 2 "$1 needs a value"
          case "$1" in --repo) repo=$2 ;; --context) ctx=$2 ;; --tier) tier=$2 ;; esac; shift 2 ;;
        *) die 2 "unknown option '$1'" ;;
      esac
    done
    [ -z "$ctx" ] || [ -f "$ctx" ] || die 2 "context file not found: $ctx"
    [ "$tier" = default ] || [ -n "$ctx" ] || die 2 "--tier $tier needs --context, whose first line is the reason"
    if [ -n "$repo" ]; then
      routed=$("$SCRIPTS/route.sh" scope "$repo") || exit $?
      [ "$routed" = "$scope" ] || die 1 "refused: $repo is in the $routed scope, not $scope"
    fi
    read_message
    healthy
    NEWDIR=$("$SCRIPTS/task-new.sh" "$scope" "$key" "$slug" "$title") || exit $?
    if [ -n "$repo" ]; then provider=$(pick_provider "$NEWDIR" "$repo") || exit 1
    else provider=$(pick_provider "$NEWDIR") || exit 1; fi
    model_of "$provider" "$tier"
    "$SCRIPTS/request-add.sh" "$NEWDIR" < "$MSG" >/dev/null || exit $?
    if [ "$fast" = 1 ]; then role=worker; "$SCRIPTS/task-set.sh" "$NEWDIR" complexity trivial || exit $?
    else role=sub-coordinator; fi
    [ -z "$repo" ] || "$SCRIPTS/task-set.sh" "$NEWDIR" repositories "$repo" || exit $?
    if [ "$tier" != default ]; then
      "$SCRIPTS/ledger.sh" "$NEWDIR" escalation "$tier: $(head -1 "$ctx")" || exit $?
    fi
    prepare "$NEWDIR" "$role" "$provider" "$MODEL" "$EFFORT" "" "$ctx"
    stop_refused "$NEWDIR"
    COMPLETE=1 ;;
  add)
    [ $# -ge 1 ] || die 2 "$usage"
    dir=$1; shift
    task_dir "$dir"
    to="" question="" ctx=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --to|--question|--context)
          [ $# -ge 2 ] || die 2 "$1 needs a value"
          case "$1" in --to) to=$2 ;; --question) question=$2 ;; --context) ctx=$2 ;; esac; shift 2 ;;
        *) die 2 "unknown option '$1'" ;;
      esac
    done
    [ -z "$ctx" ] || [ -f "$ctx" ] || die 2 "context file not found: $ctx"
    read_message
    healthy
    sub_row "$dir"
    # The sub-coordinator runs in the coordinator's folder: records made since its launch may refuse its account.
    if [ -n "$SUB_THREAD" ] && ! { "$SCRIPTS/route.sh" check "$SUB_PROVIDER" "$ROOT" &&
        "$SCRIPTS/route.sh" check-task "$SUB_PROVIDER" "$dir"; } >/dev/null 2>&1; then
      echo "stop_thread=$SUB_THREAD"
      # A headless agent is this coordinator's own process: stop it here rather than leave it to the caller.
      case "$SUB_THREAD" in pid:*) "$SCRIPTS/live.sh" --stop "$SUB_THREAD" >/dev/null 2>&1 ;; esac
      "$SCRIPTS/agent-set.sh" "$dir" "$SUB_THREAD" state stopped || exit $?
      "$SCRIPTS/ledger.sh" "$dir" decision "sub-coordinator $SUB_PROVIDER thread $SUB_THREAD may no longer run in $ROOT: stopped, a new one is prepared" || exit $?
      SUB_THREAD=""
    fi
    if [ -n "$SUB_THREAD" ]; then
      provider=$SUB_PROVIDER MODEL=$SUB_MODEL EFFORT=$SUB_EFFORT
    else
      provider=$(pick_provider "$dir") || exit 1
      model_of "$provider" default
    fi
    set -- "$dir"
    [ -z "$to" ] || set -- "$@" --to "$to"
    [ -z "$question" ] || set -- "$@" --question "$question"
    "$SCRIPTS/request-add.sh" "$@" < "$MSG" >/dev/null || exit $?
    prepare "$dir" sub-coordinator "$provider" "$MODEL" "$EFFORT" "$SUB_THREAD" "$ctx"
    COMPLETE=1 ;;
  launched)
    [ $# -eq 2 ] && [ -n "$2" ] || die 2 "$usage"
    dir=$1 thread=$2
    task_dir "$dir"
    case "$thread" in *$'\t'*|*$'\n'*|*' '*) die 2 "thread id must not contain spaces, tabs or newlines" ;; esac
    prepared "$dir"
    record "$dir" "$thread"
    echo "recorded=$thread" ;;
  launch)
    [ $# -eq 1 ] || die 2 "$usage"
    dir=$1
    task_dir "$dir"
    prepared "$dir"
    role=$(get role) provider=$(get provider) send=$(get send_to) brief=$(get brief)
    tpl=$(provider_col "$provider" 6)
    [ "$tpl" != "-" ] || die 2 "provider $provider has no launch template in $DATA/config/providers.tsv"
    if [ -n "$send" ]; then
      # A headless agent reads no further messages: an ended one is replaced, a live one is waited for.
      case "$send" in pid:*) ;; *) die 1 "prepared for thread $send: send the message there, not a new launch" ;; esac
      [ "$("$SCRIPTS/live.sh" "$send")" = ended ] || die 1 "$send is still running: launch again once it has ended"
    fi
    "$SCRIPTS/route.sh" check-task "$provider" "$dir" || exit 1
    "$SCRIPTS/route.sh" check "$provider" "$ROOT" || exit 1
    healthy
    mkdir -p "$dir/runs" || die 1 "cannot write in $dir"
    nn=$(basename "$brief"); nn=${nn%%-*}
    log=$dir/runs/$nn-$role.log
    cmd=${tpl//\{dir\}/\"\$AGENT_DIR\"}
    cmd=${cmd//\{model\}/\"\$AGENT_MODEL\"}
    cmd=${cmd//\{effort\}/\"\$AGENT_EFFORT\"}
    cmd=${cmd//\{brief\}/\"\$AGENT_BRIEF\"}
    # Job control gives the agent its own process group: no terminal signal reaches it, and the group is what is stopped.
    set -m
    AGENT_DIR=$ROOT AGENT_MODEL=$(get model) AGENT_EFFORT=$(get effort) AGENT_BRIEF=$brief \
      nohup env -u COORD_ROLE -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID bash -c "$cmd" < /dev/null > "$log" 2>&1 &
    pid=$!
    set +m
    # What tells this agent from a later process that reuses its id (live.sh, the agent-runs sweep).
    printf '%s\t%s\n' "$pid" "$(proc_start "$pid")" > "${log%.log}.start"
    thread=pid:$pid
    if [ -n "$send" ]; then
      [ "$(T=$send awk -F'\t' '$8==ENVIRON["T"] {s=$11} END {print s}' "$dir/agents.tsv")" != running ] ||
        "$SCRIPTS/agent-set.sh" "$dir" "$send" state stopped >/dev/null
      tmp=$(mktemp "$dir/.dispatch.XXXXXX") && sed 's/^send_to=.*/send_to=/' "$dir/.dispatch" > "$tmp" && mv "$tmp" "$dir/.dispatch"
    fi
    if ! "$SCRIPTS/resource-add.sh" "$dir" agent-runs "$pid" "$thread" >/dev/null || ! (record "$dir" "$thread"); then
      kill -TERM -- "-$pid" 2>/dev/null
      "$SCRIPTS/resource-done.sh" "$dir" agent-runs "$pid" >/dev/null 2>&1
      die 1 "agent started and stopped again: it could not be recorded"
    fi
    echo "thread=$thread"
    echo "log=$log" ;;
  tasks)
    [ $# -le 1 ] || die 2 "$usage"
    want=${1:-}
    rows=$(
      for t in "$DATA"/tasks/*/*/task.md; do
        [ -f "$t" ] && [ "$(field "$t" status)" = open ] || continue
        d=$(dirname "$t")
        if [ -n "$want" ]; then
          W=$want N="$(basename "$d") $(field "$t" key)" TI=$(field "$t" title) awk 'BEGIN {
            w = tolower(ENVIRON["W"]); exit !(index(tolower(ENVIRON["N"]), w) || index(tolower(ENVIRON["TI"]), w)) }' || continue
        fi
        sub_row "$d"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(field "$t" created)" "$(name_of "$d")" "$(field "$t" title)" \
          "$(field "$t" stage)" "${SUB_THREAD:--}" "$d"
      done | sort | cut -f2-
    )
    if [ -z "$rows" ]; then echo none; else printf '%s\n' "$rows"; fi ;;
  *) die 2 "$usage" ;;
esac
