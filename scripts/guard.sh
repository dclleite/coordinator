#!/bin/bash
# guard.sh            PreToolUse hook: reads one tool call as JSON on stdin and allows, warns or blocks it.
# guard.sh claim      records the current thread as the coordinator's.
set -u

# Fast path, no fork: the hook fires on every tool call of every session in this folder.
_dir=${0%/*}; [ "$_dir" != "$0" ] || _dir=.
_data=${COORD_DATA:-${COORD_ROOT:-$_dir/..}/.private}
_thread=${T3CODE_THREAD_ID:-${CLAUDE_CODE_SESSION_ID:-}}
if [ "${1:-}" != claim ] && [ "${COORD_ROLE:-}" != coordinator ]; then
  [ -f "$_data/coordinator-thread" ] || exit 0
  _claimed=; read -r _claimed < "$_data/coordinator-thread" || true
  [ -n "$_claimed" ] || exit 0
  [ -z "$_thread" ] || [ "$_thread" = "$_claimed" ] || exit 0
fi

. "$(dirname "$0")/lib.sh"

if [ "${1:-}" = claim ]; then
  [ $# -eq 1 ] || die 2 "usage: guard.sh claim"
  [ -n "$_thread" ] || die 2 "no thread id: neither T3CODE_THREAD_ID nor CLAUDE_CODE_SESSION_ID is set"
  [ -d "$DATA" ] || die 2 "no data folder: $DATA"
  printf '%s\n' "$_thread" > "$DATA/coordinator-thread"
  echo "coordinator-thread=$_thread"; exit 0
fi
[ $# -eq 0 ] || die 2 "usage: guard.sh < hook-input | guard.sh claim"
# Without awk nothing can be parsed; a guard that breaks every session is worse than none.
command -v awk >/dev/null 2>&1 || exit 0

mode=${GUARD_MODE:-}
if [ -z "$mode" ] && [ -f "$ROOT/config/guard.conf" ]; then
  mode=$(awk -F= '$1=="GUARD_MODE" {v=$2} END {print v}' "$ROOT/config/guard.conf")
fi
# Off still parses: the reminder for an action that needs the developer's word is never switched off.
case "$mode" in off|warn|block) ;; *) mode=warn ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/guard.XXXXXX") || exit 0
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/in"

log() {
  [ -d "$DATA" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" >> "$DATA/guard.log" 2>/dev/null || true
}

# Writes the wanted string fields of the hook input to $tmp/f.<name>; exit 1 when the JSON is malformed.
LC_ALL=C awk -v out="$tmp/f." '
function want(p) { return p=="tool_name" || p=="session_id" || p=="agent_id" || p=="cwd" ||
  p=="tool_input.command" || p=="tool_input.file_path" || p=="tool_input.path" || p=="tool_input.notebook_path" }
function unesc(r,   o, j, e, h, x) {
  o = ""
  while ((j = index(r, "\\")) > 0) {
    o = o substr(r, 1, j - 1); e = substr(r, j + 1, 1); r = substr(r, j + 2)
    if (e == "n") o = o "\n"; else if (e == "t") o = o "\t"; else if (e == "r") o = o "\r"
    else if (e == "b" || e == "f") o = o " "
    else if (e == "u") {
      h = tolower(substr(r, 1, 4)); r = substr(r, 5)
      # Only ASCII is decoded, so an escaped shell character is still seen as one.
      if (substr(h, 1, 2) == "00" && index("01234567", substr(h, 3, 1))) {
        x = (index("0123456789abcdef", substr(h, 3, 1)) - 1) * 16 + index("0123456789abcdef", substr(h, 4, 1)) - 1
        o = o sprintf("%c", x)
      } else o = o "\\u" h
    } else o = o e
  }
  return o r
}
BEGIN { s = ""; n = 0 }
{ s = (n++ ? s "\n" : "") $0 }
END {
  # Split on quotes so long string values are never walked character by character.
  np = split(s, P, "\""); d = 0; bad = 0; seen = 0
  for (q = 1; q <= np && !bad; q++) {
    seg = P[q]
    if (!instr) {
      L = length(seg)
      for (i = 1; i <= L && !bad; i++) {
        c = substr(seg, i, 1)
        if (c == "{" || c == "[") {
          if (d == 0 && seen) bad = 1
          seen = 1; d++; t[d] = (c == "{") ? "o" : "a"; wk[d] = (c == "{"); k[d] = ""
        } else if (c == "}" || c == "]") {
          if (d < 1 || t[d] != ((c == "}") ? "o" : "a")) bad = 1; else d--
        } else if (c == ",") { if (d < 1) bad = 1; else if (t[d] == "o") wk[d] = 1 }
        else if (c == ":" || c == " " || c == "\t" || c == "\n" || c == "\r") { }
        else if (d < 1) bad = 1
      }
      if (q < np) {
        if (d < 1) bad = 1; instr = 1; v = ""; iskey = (t[d] == "o" && wk[d])
        p = iskey ? "" : (d == 1) ? k[1] : (d == 2 && k[1] == "tool_input" && t[1] == "o" && t[2] == "o") ? "tool_input." k[2] : ""
        keep = iskey || (p != "" && want(p))
      }
    } else {
      if (keep) v = v seg
      # A quote after an odd run of backslashes is part of the string; only strings we keep are joined.
      b = 0; j = length(seg); while (j > 0 && substr(seg, j, 1) == "\\") { b++; j-- }
      if (b % 2 == 1) { if (keep) v = v "\""; continue }
      if (q == np) { bad = 1; break }
      instr = 0
      if (iskey) { k[d] = unesc(v); wk[d] = 0 }
      else if (keep) { f = out p; printf "%s", unesc(v) > f; close(f) }
    }
  }
  if (bad || instr || d != 0 || !seen) exit 1
}' "$tmp/in" || { log - malformed input; exit 0; }

get() { [ -f "$tmp/f.$1" ] && cat "$tmp/f.$1"; }
tool=$(get tool_name | tr -c 'A-Za-z0-9_.-' '_')
[ -n "$tool" ] || { log - malformed no-tool-name; exit 0; }
# A subagent of this session is the coordinator's delegate, not the coordinator.
[ ! -s "$tmp/f.agent_id" ] || exit 0
if [ "${COORD_ROLE:-}" != coordinator ] && [ -z "$_thread" ]; then
  [ "$(get session_id)" = "$_claimed" ] || exit 0
fi
cwd=$(get cwd); [ -n "$cwd" ] || cwd=$(pwd -P)

# inside <path> <dir>...: the path, resolved through its nearest existing folder, is inside one of the dirs.
inside() {
  local p=$1 rest="" base real d; shift
  case "/$p/" in */../*) return 1 ;; esac
  case "$p" in /*) ;; *) p=$cwd/$p ;; esac
  while [ ! -d "$p" ]; do
    base=${p##*/}; rest=/$base$rest; p=${p%/*}; [ -n "$p" ] || p=/
  done
  real=$(physical "$p")$rest
  for d in "$@"; do
    d=$(physical "$d"); [ -n "$d" ] || continue
    case "$real/" in "$d"/*) return 0 ;; esac
  done
  return 1
}

allowed_script() {
  local w=$1 dir
  case "$w" in */*) ;; *) return 1 ;; esac
  case "$w" in *[*?[]*) return 1 ;; esac
  case "$w" in /*) ;; *) w=$cwd/$w ;; esac
  dir=$(physical "${w%/*}")
  [ -n "$dir" ] && [ "$dir" = "$(physical "$ROOT/scripts")" ] || return 1
  case "${w##*/}" in dispatch.sh|report.sh|status.sh|hold.sh|service.sh|panel.sh|guard.sh) return 0 ;; esac
  return 1
}

# Prints "CMD <word>" per simple command, "IN <path>" per input redirection, "REJECT <why>" on anything else.
shell_parts() {
  LC_ALL=C awk -v q="'" '
  function endword() {
    if (!inw) return
    if (index(w, "\n")) print "REJECT\tnewline in a word"
    if (redir == "in") print "IN\t" w
    else if (redir == "out") { if (w != "/dev/null") print "REJECT\tredirection" }
    else if (redir == "hd") { hq[++nh] = w; hquote[nh] = wq; hstrip[nh] = hs }
    else if (redir == "str") { }
    else if (idx == 0 && !wq && w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) print "REJECT\tassignment"
    else if (idx == 0 && !wq && (w == "bash" || w == "sh")) idx = -1
    else { if (idx <= 0) print "CMD\t" w; else print "ARG\t" w; idx = 1 }
    if (redir != "") redir = ""; w = ""; inw = 0; wq = 0
  }
  function endcmd() { endword(); if (idx < 0) print "REJECT\tshell"; idx = 0 }
  function heredocs(   j, line, e, del) {
    for (j = 1; j <= nh; j++) {
      while (1) {
        if (i > L) return
        e = index(substr(s, i), "\n"); if (e == 0) e = L - i + 2
        line = substr(s, i, e - 1); i += e
        del = line; if (hstrip[j]) sub(/^\t+/, "", del)
        if (del == hq[j]) break
        if (!hquote[j] && (line ~ /\$\(/ || index(line, "`"))) print "REJECT\tsubstitution"
      }
    }
    nh = 0
  }
  BEGIN { s = ""; n = 0 }
  { s = (n++ ? s "\n" : "") $0 }
  END {
    L = length(s); idx = 0; inw = 0; w = ""; redir = ""; nh = 0
    for (i = 1; i <= L; i++) {
      c = substr(s, i, 1); c2 = substr(s, i, 2)
      if (c == "\\") {
        if (substr(s, i+1, 1) == "\n") { i++; continue }
        i++; w = w substr(s, i, 1); inw = 1; wq = 1
      } else if (c == q || c2 == "$" q) {
        if (c2 == "$" q) i++
        e = index(substr(s, i+1), q); if (e == 0) { print "REJECT\tunterminated quote"; exit }
        w = w substr(s, i+1, e-1); i += e; inw = 1; wq = 1
      } else if (c == "\"") {
        for (i++; i <= L; i++) {
          c = substr(s, i, 1)
          if (c == "\"") break
          if (c == "\\") { i++; w = w substr(s, i, 1); continue }
          if (c == "`" || substr(s, i, 2) == "$(") print "REJECT\tsubstitution"
          w = w c
        }
        if (i > L) { print "REJECT\tunterminated quote"; exit }
        inw = 1; wq = 1
      } else if (c == "`" || c2 == "$(") { print "REJECT\tsubstitution"; inw = 1
      } else if (c2 == "<(" || c2 == ">(") { print "REJECT\tsubstitution"; i++
      } else if (c == "(" || c == ")") { print "REJECT\tsubshell"
      } else if (c == "#" && !inw) {
        e = index(substr(s, i), "\n"); if (e == 0) break; i += e - 2
      } else if (c == " " || c == "\t") { endword()
      } else if (c == "\n") { endcmd(); i++; heredocs(); i--
      } else if (c == ";" || c == "|" || (c == "&" && substr(s, i+1, 1) != ">")) {
        endcmd(); if (substr(s, i+1, 1) == c || (c == "|" && substr(s, i+1, 1) == "&")) i++
      } else if (c == "<" || c == ">" || c == "&") {
        if (inw && w ~ /^[0-9]+$/ && !wq) { w = ""; inw = 0 } else endword()
        op = c; while (index("<>&|-", substr(s, i+1, 1)) && length(op) < 3) { i++; op = op substr(s, i, 1) }
        if (op == "<<<") redir = "str"
        else if (op == "<<" || op == "<<-") { redir = "hd"; hs = (op == "<<-") }
        else if (op == "<") redir = "in"
        else if (op ~ /&-$/) { }
        else if (op ~ /[<>]&$/ && substr(s, i+1) ~ /^([0-9]+|-)([^0-9A-Za-z_]|$)/) {
          while (substr(s, i+1, 1) ~ /[0-9-]/) i++ }
        else redir = "out"
      } else { w = w c; inw = 1 }
    }
    endcmd()
    if (redir != "") print "REJECT\tredirection"
  }' "$tmp/f.tool_input.command"
}

rule=""; remind=0
case "$tool" in
  Bash)
    [ -f "$tmp/f.tool_input.command" ] || : > "$tmp/f.tool_input.command"
    shell_parts > "$tmp/parts"
    # Lifting a hold, a confirmed service verb or a developer's tier is the developer's call, given in this thread.
    awk -F'\t' '$1 == "CMD" { c = $2; sub(/.*\//, "", c); n = 0; a = "" }
      $1 == "ARG" { if (++n == 1) a = $2; if ((c == "hold.sh" && a == "off") || (c == "service.sh" && a == "run" && $2 == "--confirmed") ||
        (c == "dispatch.sh" && $2 == "--developer-said")) r = 1 }
      END { exit !r }' "$tmp/parts" && remind=1
    if grep -q '^REJECT' "$tmp/parts" || ! grep -q '^CMD' "$tmp/parts"; then rule=shell
    else
      while IFS=$'\t' read -r kind word; do
        case "$kind" in
          CMD) allowed_script "$word" || { rule=shell; break; } ;;
          IN) inside "$word" "$ROOT" "$DATA" || { rule=shell; break; } ;;
        esac
      done < "$tmp/parts"
    fi ;;
  Read|Grep|Glob|LS)
    p=$(get tool_input.file_path); [ -n "$p" ] || p=$(get tool_input.path); [ -n "$p" ] || p=$cwd
    inside "$p" "$ROOT" "$DATA" || rule=read ;;
  Write|Edit|MultiEdit|NotebookEdit)
    p=$(get tool_input.file_path); [ -n "$p" ] || p=$(get tool_input.notebook_path)
    if [ -z "$p" ] || ! inside "$p" "$DATA"; then rule=write
    else
      # Records change only through their scripts; the coordinator writes messages and context only.
      # Lowercased: on a case-insensitive volume TASK.md is task.md.
      lp=$(printf '%s' "/${p#"$DATA"}" | tr 'A-Z' 'a-z')
      case "$lp" in
        */handoffs/*|*/briefs/*|*/config/*|*/services/*) rule=write ;;
        */request.md|*/task.md|*/agents.tsv|*/ledger.md|*/contract.md|*/inbox.tsv|*/board.md|*/board.json|*/coordinator-thread|*/guard.log|*/.dispatch) rule=write ;;
        */public-allow.txt|*/sensitive-terms.txt) rule=write ;;
      esac
    fi ;;
  Agent|Task|SendMessage|ListAgents|TaskStop|AskUserQuestion|ToolSearch) ;;
  mcp__t3*__delegate_task|mcp__t3*__t3_thread_launch|mcp__t3*__t3_thread_send|mcp__t3*__t3_thread_read|\
  mcp__t3*__t3_thread_wait|mcp__t3*__t3_background_wait|mcp__t3*__task_status|mcp__t3*__task_cancel|\
  mcp__t3*__t3_thread_interrupt|mcp__t3*__t3_pending_request|mcp__t3*__t3_thread_list|mcp__t3*__t3_thread_search|\
  mcp__t3*__t3_thread_organize|mcp__t3*__t3_thread_update|mcp__t3*__orchestrator_capabilities|\
  mcp__t3*__t3_project_list|mcp__t3*__t3_project_read|mcp__t3*__t3_project_create|\
  mcp__t3*__html_preview|mcp__t3*__html_render) ;;
  *) rule=tool ;;
esac
[ "$mode" != off ] || rule=""
reminder="Coordinator guard: only with the developer's explicit word for this action, in this conversation."
if [ -z "$rule" ]; then
  [ "$remind" -eq 1 ] || exit 0
  log "$tool" remind confirm-word
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$(json_str "$reminder")"
  exit 0
fi

case "$rule" in
  shell) why="the coordinator runs only scripts/dispatch.sh, report.sh, status.sh, hold.sh, service.sh, panel.sh and guard.sh, each on its own" ;;
  read) why="the coordinator reads and searches only inside its own folder" ;;
  write) why="the coordinator writes only message and context files inside its data folder" ;;
  *) why="$tool is not one of the coordinator's tools" ;;
esac
line="Coordinator guard ($mode): $why. Delegate the work instead: scripts/dispatch.sh new for a new task, scripts/dispatch.sh add for an open one."
[ "$remind" -eq 0 ] || line="$reminder $line"
if [ "$mode" = block ]; then
  log "$tool" block "$rule"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_str "$line")"
else
  log "$tool" warn "$rule"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$(json_str "$line")"
fi
