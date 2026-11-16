. "$(dirname "$0")/lib.sh"
DOCS=("$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/playbooks" "$ROOT/roles" "$ROOT/runtimes")
# Every script an agent may run is named where agents read; panel.sh is named before it lands.
for f in "$ROOT"/scripts/*.sh panel.sh; do
  s=$(basename "$f"); case $s in lib.sh|worktree-rules.sh) continue ;; esac  # sourced, never run
  ok "$s is referenced" grep -rqF "$s" "${DOCS[@]}"
done
for f in intake align build status cleanup setup; do
  ok "playbook $f" test -s "$ROOT/playbooks/$f.md"
  ok "playbook $f says who runs it" sh -c "sed -n 3p '$ROOT/playbooks/$f.md' | grep -q '^Run by'"
done
for r in worker sub-coordinator fast-worker; do ok "role $r" test -s "$ROOT/roles/$r.md"; done
# dispatch.sh fills these three placeholders in the two role files it reads.
for r in sub-coordinator fast-worker; do
  for p in '[task]' '[task-dir]' '[coordinator path]'; do
    ok "roles/$r.md has $p" grep -qF "$p" "$ROOT/roles/$r.md"
  done
done
ok "fast worker heading" grep -qx '# Context for a fast worker' "$ROOT/roles/fast-worker.md"
ok "never writes product code" grep -qi "never writes product code" "$ROOT/AGENTS.md"
ok "account boundary by kinds" grep -q "check on account kinds" "$ROOT/AGENTS.md"
ok "long waits rule" grep -q "Long waits belong to the agent that owns them" "$ROOT/AGENTS.md"
ok "private data rule" grep -q "public-check.sh" "$ROOT/AGENTS.md"
ok "reply language" grep -q "language the developer writes in" "$ROOT/AGENTS.md"
for r in t3 terminal; do ok "runtime $r" test -s "$ROOT/runtimes/$r.md"; done
ok "playbooks name no runtime tool" sh -c "! grep -rqE 't3_thread|delegate_task|task_cancel|html_render|mcp__' '$ROOT/playbooks' '$ROOT/roles'"
ok "launch tool named" grep -qE "t3_thread_launch|delegate_task" "$ROOT/runtimes/t3.md"
ok "design restores the review slot" grep -q "^## Review slot" "$ROOT/docs/design.md"
ok "design has non-goals" grep -q "^## Non-goals" "$ROOT/docs/design.md"
ok "design names the permission mode" grep -qi "narrowest permission mode" "$ROOT/docs/design.md"
# Statements this round made false: the repository is pushed, and a delegated task cannot target another project.
ok "nothing says pushing is off" sh -c "! grep -rqiE 'never pushed|nothing is pushed|pushing stays off|never push|push guard|no remote|remote may come later|remote later' '$ROOT/AGENTS.md' '$ROOT/README.md' '$ROOT/playbooks' '$ROOT/roles' '$ROOT/runtimes' '$ROOT/docs'"
ok "no delegated launch into another project" sh -c "! grep -rqE 'can name another project|target: \{projectId|delegate into .<personal-repo>.' '$ROOT/AGENTS.md' '$ROOT/playbooks' '$ROOT/roles' '$ROOT/runtimes' '$ROOT/docs'"
eq "AGENTS.md stays short" yes "$([ "$(wc -l < "$ROOT/AGENTS.md")" -le 80 ] && echo yes || echo no)"

# Lines the fixes of the readings, the routing table and the launcher made true.
ok "a steering note is not the developer's words" grep -qF "neither a message from its launcher nor the result of its own child" "$ROOT/AGENTS.md"
ok "check-task reads every repository" grep -qF "\`check-task\` also checks every path in the task's \`repositories:\`" "$ROOT/AGENTS.md"
ok "a silent container engine stops no launch" grep -qF "does not answer reads \`containers=unknown\`" "$ROOT/README.md"
ok "an agent started by hand is marked" grep -qF "live.sh --mark <task-dir> pid:<n>" "$ROOT/runtimes/terminal.md"
ok "a refused routing row is explained" grep -qF "every \`route.sh\` call stops with the line number" "$ROOT/playbooks/setup.md"
ok "--repo must lie in the scope" grep -qF "it must lie in the task's scope" "$ROOT/playbooks/intake.md"

# Lines the second review made true.
ok "the message folder is named, passed with <" grep -qF 'a file under `.private/messages/`' "$ROOT/AGENTS.md"
ok "intake names the message folder" grep -qF '.private/messages/' "$ROOT/playbooks/intake.md"
ok "intake: < not a pipe" grep -qF 'with `<`' "$ROOT/playbooks/intake.md"
ok "intake: a stop_thread line is acted on" grep -qF 'stop_thread=' "$ROOT/playbooks/intake.md"
ok "intake: omit --repo when the first repository is personal" grep -qF 'omit `--repo`' "$ROOT/playbooks/intake.md"
eq "status: only a fast worker runs the orphan sweep" "" "$(grep -F 'sweep.sh --orphans' "$ROOT/playbooks/status.md" | grep -v 'a fast worker runs')"
ok "status: orphans come from the board" grep -qi 'orphan' "$ROOT/playbooks/status.md"
eq "worker: every coordinator script carries the coordinator path" "" "$(grep -oE '(^|[^]/])scripts/(resource-add|resource-done|browser|hold|handoff-write|brief-check)\.sh' "$ROOT/roles/worker.md")"
ok "worker: a created worktree is recorded" grep -qF '[coordinator path]/scripts/resource-add.sh [task-dir] worktrees <path>' "$ROOT/roles/worker.md"
ok "cleanup: only recorded worktrees" grep -qF 'worktrees <path>' "$ROOT/playbooks/cleanup.md"
