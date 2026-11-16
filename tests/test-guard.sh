. "$(dirname "$0")/lib.sh"; mktask; G="$ROOT/scripts/guard.sh"
unset COORD_ROLE GUARD_MODE T3CODE_THREAD_ID CLAUDE_CODE_SESSION_ID
F=$COORD_ROOT; mkdir -p "$F/scripts"; : > "$F/scripts/dispatch.sh"; : > "$F/scripts/board.sh"

# hook <tool> <input-object>: prints the guard's stdout for one PreToolUse call made from $F.
hook() { printf '{"session_id":"s-1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$F" "$1" "$2" | "$G"; }
bash_in() { (. "$ROOT/scripts/lib.sh"; printf '{"command":%s}' "$(json_str "$1")"); }
# Built here: bash 3.2 brace-expands {a,b} written inside "$(...)".
fp() { printf '{"file_path":"%s","content":"x","old_string":"a","new_string":"b"}' "$1"; }
raw() { printf '{"session_id":"%s","agent_id":"%s","tool_name":"Bash","tool_input":{"command":"rm x"}}' "$1" "$2"; }
as_coord() { COORD_ROLE=coordinator "$@"; }
warned() { grep -q '"additionalContext":"Coordinator guard (warn): ' <<< "$1"; }
blocked() { grep -q '"permissionDecision":"deny".*Coordinator guard (block): ' <<< "$1"; }
logged() { [ "$(wc -l < "$COORD_DATA/guard.log" 2>/dev/null | tr -d ' ')" = "$1" ]; }

eq "not the coordinator: silent" "" "$(hook Bash "$(bash_in 'rm -rf x')")"
mv "$F/config/guard.conf" "$F/config/guard.off"
eq "not the coordinator, no configuration: silent" "" "$(hook Bash "$(bash_in 'git commit -m x')")"
mv "$F/config/guard.off" "$F/config/guard.conf"
ok "not the coordinator: nothing logged" test ! -e "$COORD_DATA/guard.log"

eq "dispatch new allowed" "" "$(as_coord hook Bash "$(bash_in "scripts/dispatch.sh new personal - slug \"A title\" <<'MSG'
the developer wrote; rm -rf / && \$(whoami) | x
MSG")")"
eq "absolute path, chain of allowed scripts, fd redirect" "" "$(as_coord hook Bash "$(bash_in "$F/scripts/dispatch.sh tasks foo 2>&1 && ./scripts/dispatch.sh tasks >/dev/null")")"
eq "input from a file inside the folder" "" "$(as_coord hook Bash "$(bash_in "scripts/dispatch.sh add x < $COORD_DATA/msg.txt")")"
eq "panel allowed" "" "$(as_coord hook Bash "$(bash_in 'scripts/panel.sh start && scripts/panel.sh url')")"
eq "comment after the command" "" "$(as_coord hook Bash "$(bash_in 'scripts/dispatch.sh tasks # && rm x')")"
eq "ToolSearch allowed" "" "$(as_coord hook ToolSearch '{"query":"select:x"}')"
eq "runtime launch allowed" "" "$(as_coord hook mcp__t3-code__delegate_task '{"task":"x"}')"
eq "runtime send allowed" "" "$(as_coord hook mcp__t3-code__t3_thread_send '{"threadId":"t"}')"
eq "read inside the folder" "" "$(as_coord hook Read "$(fp "$F/config/guard.conf")")"
eq "grep with no path searches the folder" "" "$(as_coord hook Grep '{"pattern":"x"}')"
eq "message file inside DATA" "" "$(as_coord hook Write "$(fp "$COORD_DATA/msg.txt")")"
eq "escaped quotes in a title" "" "$(as_coord hook Bash "$(bash_in 'scripts/dispatch.sh new p - s "A \"quoted\" title"')")"
ok "allows are not logged" test ! -e "$COORD_DATA/guard.log"
# The folder AGENTS.md names for the developer's message: its Write and the call that reads it pass in block mode.
eq "block: the message file under .private/messages" "" "$(GUARD_MODE=block as_coord hook Write "$(fp "$COORD_DATA/messages/m-1.md")")"
eq "block: dispatch reads it with <" "" "$(GUARD_MODE=block as_coord hook Bash "$(bash_in 'scripts/dispatch.sh add x < .private/messages/m-1.md')")"
ok "block: a pipe into dispatch is refused" blocked "$(GUARD_MODE=block as_coord hook Bash "$(bash_in 'cat .private/messages/m-1.md | scripts/dispatch.sh add x')")"
rm -f "$COORD_DATA/guard.log"

for cmd in 'scripts/dispatch.sh tasks && rm -rf x' '../panel.sh start' 'git commit -m x' 'scripts/board.sh' 'scripts/dispatch.sh tasks | sh' \
  'scripts/dispatch.sh tasks > out.txt' 'scripts/dispatch.sh tasks "$(rm x)"' 'scripts/dispatch.sh `id`' \
  'X=1 scripts/dispatch.sh tasks' 'dispatch.sh tasks' 'scripts/dispatch.sh tasks < /etc/passwd' \
  "scripts/dispatch.sh add x <<MSG
\$(rm -rf x)
MSG" 'scripts/dispatch.sh tasks; (rm x)' 'scripts/../scripts/board.sh' 'bash -c "rm x"' 'scripts/dispatch.sh "unterminated'; do
  ok "warned: $cmd" warned "$(as_coord hook Bash "$(bash_in "$cmd")")"
done
ok "a shell character written as a unicode escape is still seen" warned "$(as_coord hook Bash '{"command":"scripts/dispatch.sh tasks \u0026\u0026 rm x"}')"
ok "edit of a tracked script warned" warned "$(as_coord hook Edit "$(fp "$F/scripts/dispatch.sh")")"
ok "edit of a task record warned" warned "$(as_coord hook Edit "$(fp "$COORD_DATA/tasks/p/t/task.md")")"
ok "read outside the folder warned" warned "$(as_coord hook Read '{"file_path":"/etc/hosts"}')"
ok "read escaping with .. warned" warned "$(as_coord hook Read "$(fp "$F/../x")")"
ok "other tool warned" warned "$(as_coord hook WebFetch '{"url":"https://example.invalid"}')"
ok "warn names the rule and the way out" grep -q 'runs only scripts/dispatch.sh.*Delegate the work instead: scripts/dispatch.sh' <<< "$(as_coord hook Bash "$(bash_in 'git status')")"

: > "$COORD_DATA/guard.log"
out=$(as_coord hook Bash "$(bash_in 'echo secret-input-text')")
ok "warn is logged" logged 1
fails 1 "the log never holds the input" grep -q 'secret-input-text' "$COORD_DATA/guard.log"
eq "log line: time, tool, verdict, rule" "Bash warn shell" "$(cut -f2- "$COORD_DATA/guard.log" | tr '\t' ' ')"

printf 'GUARD_MODE=block\n' > "$F/config/guard.conf"
ok "block: chain refused" blocked "$(as_coord hook Bash "$(bash_in 'scripts/dispatch.sh tasks && rm -rf x')")"
ok "block: git commit refused" blocked "$(as_coord hook Bash "$(bash_in 'git commit -m x')")"
ok "block: script edit refused" blocked "$(as_coord hook Write "$(fp "$F/scripts/dispatch.sh")")"
ok "block: outside read refused" blocked "$(as_coord hook Read '{"file_path":"/etc/hosts"}')"
eq "block: dispatch still allowed" "" "$(as_coord hook Bash "$(bash_in 'scripts/dispatch.sh tasks')")"
eq "block: launch still allowed" "" "$(as_coord hook mcp__t3-code__t3_thread_launch '{}')"
eq "block: not the coordinator still silent" "" "$(hook Bash "$(bash_in 'rm -rf x')")"

: > "$COORD_DATA/guard.log"
eq "malformed input allowed" "" "$(printf '{"tool_name":"Bash","tool_input":{"command":"rm' | COORD_ROLE=coordinator "$G")"
eq "non-JSON input allowed" "" "$(printf 'not json' | COORD_ROLE=coordinator "$G")"
ok "malformed input logged" logged 2
eq "malformed logged as such" "malformed" "$(cut -f3 "$COORD_DATA/guard.log" | sort -u)"

printf 'GUARD_MODE=off\n' > "$F/config/guard.conf"
eq "off: everything allowed" "" "$(as_coord hook Bash "$(bash_in 'rm -rf x')")"
printf 'GUARD_MODE=block\n' > "$F/config/guard.conf"
eq "GUARD_MODE=off in the environment" "" "$(GUARD_MODE=off as_coord hook Bash "$(bash_in 'rm -rf x')")"
eq "a subagent of the coordinator is not the coordinator" "" "$(raw s a1 | COORD_ROLE=coordinator "$G")"

# Claimed thread: the coordinator is recognized by its thread id, every other thread passes.
fails 2 "claim needs a thread id" "$G" claim
eq "claim prints the id" "coordinator-thread=thread:abc" "$(T3CODE_THREAD_ID=thread:abc "$G" claim)"
eq "claim writes the file" "thread:abc" "$(cat "$COORD_DATA/coordinator-thread")"
ok "claimed thread is guarded" blocked "$(T3CODE_THREAD_ID=thread:abc hook Bash "$(bash_in 'git push')")"
eq "another thread is not" "" "$(T3CODE_THREAD_ID=thread:other hook Bash "$(bash_in 'git push')")"
CLAUDE_CODE_SESSION_ID=s-1 "$G" claim >/dev/null
ok "claimed session id is guarded" blocked "$(CLAUDE_CODE_SESSION_ID=s-1 hook Bash "$(bash_in 'git push')")"
ok "session id read from the input when the environment has none" blocked "$(hook Bash "$(bash_in 'git push')")"
eq "another session id in the input" "" "$(raw s-2 "" | "$G")"

ok "settings hook runs the guard for every tool" grep -q '"matcher": "\*"' "$ROOT/.claude/settings.json"
ok "settings hook path works from any clone" grep -qF '"\"${CLAUDE_PROJECT_DIR}\"/scripts/guard.sh"' "$ROOT/.claude/settings.json"
eq "guard ships in warn mode" "GUARD_MODE=warn" "$(cat "$ROOT/config/guard.conf")"

# Lifting a hold and a confirmed service verb stay possible, with one reminder line in every mode.
reminded() { grep -q "Coordinator guard: only with the developer's explicit word for this action, in this conversation" <<< "$1" \
  && ! grep -q '"permissionDecision"' <<< "$1"; }
for m in warn block off; do
  printf 'GUARD_MODE=%s\n' "$m" > "$F/config/guard.conf"
  ok "$m: hold off reminded, not refused" reminded "$(as_coord hook Bash "$(bash_in 'scripts/hold.sh off personal/t')")"
  ok "$m: hold off --all reminded" reminded "$(as_coord hook Bash "$(bash_in 'scripts/hold.sh off --all')")"
  ok "$m: confirmed service verb reminded" reminded "$(as_coord hook Bash "$(bash_in 'scripts/service.sh run acme restart --confirmed')")"
  eq "$m: hold on is silent" "" "$(as_coord hook Bash "$(bash_in 'scripts/hold.sh on personal/t')")"
  eq "$m: unconfirmed service verb is silent" "" "$(as_coord hook Bash "$(bash_in 'scripts/service.sh run acme ping')")"
done
printf 'GUARD_MODE=block\n' > "$F/config/guard.conf"
out=$(as_coord hook Bash "$(bash_in 'scripts/hold.sh off x && rm -rf y')")
ok "block: a reminder never lets a refused chain through" blocked "$out"
ok "block: the refusal carries the reminder too" grep -q "explicit word for this action" <<< "$out"
: > "$COORD_DATA/guard.log"; as_coord hook Bash "$(bash_in 'scripts/hold.sh off x')" >/dev/null
eq "reminder logged" "Bash remind confirm-word" "$(cut -f2- "$COORD_DATA/guard.log" | tr '\t' ' ')"
eq "not the coordinator: no reminder" "" "$(T3CODE_THREAD_ID=thread:other hook Bash "$(bash_in 'scripts/hold.sh off x')")"

# Record names are compared without case, and the public check's lists are not the coordinator's to write.
for p in tasks/p/t/TASK.md tasks/p/t/Ledger.MD tasks/p/t/HANDOFFS/x.md public-allow.txt sensitive-terms.txt Public-Allow.TXT; do
  ok "block: write to $p refused" blocked "$(as_coord hook Write "$(fp "$COORD_DATA/$p")")"
done
eq "block: a message file is still allowed" "" "$(as_coord hook Write "$(fp "$COORD_DATA/msg.txt")")"
