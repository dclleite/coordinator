# Cleanup

Run by the sub-coordinator of the task (or a fast worker the coordinator starts for it), when the task's MR is merged or the developer abandons it.
The order matters: a closed task's resources are no longer counted as owned.

- `scripts/sweep.sh <task-dir>` first: it stops what the task recorded and is still alive, headless agents (kind `agent-runs`) included. Containers and browser profiles need `--confirmed`, which only the developer gives.
- For a squash-merged MR the branch may be gone from the remote. Record the MR's head commit first, so the worktree counts as merged: `scripts/agent-set.sh <task-dir> <thread-id> mr_sha <sha>`.
- `scripts/worktree-cleanup.sh <task-dir>` removes each recorded worktree that the task recorded as made (`resource-add.sh <task-dir> worktrees <path>`, written when it was created), that is clean, whose work is on the remote, that no other open task records, and that lies in the repository's `.claude/worktrees/` or a folder listed in `.private/config/worktree-roots.txt`. Anything else is kept, with the reason printed. It never forces: a worktree with uncommitted changes or unpushed commits is kept, with the reason printed. It skips every path a service protects.
- Removing a worktree also deletes its ignored files (dependencies, build output, local env files). If a worker reported a local file worth keeping, copy it into the task folder first.
- When git refuses a removal, the script queues it in `.private/tasks/cleanup-pending.tsv`. Say how many are queued and how much disk they hold; `scripts/cleanup-pending.sh` retries them.
- The script removes worktrees, never branches. Local branches left behind (often pointing at commits from before a rewrite or a squash) are listed in the handoff and deleted only with the developer's word.
- Knowledge worth keeping about the company's systems goes into that repository's own docs through a task there, not into the coordinator (`AGENTS.md` rule 14).
- `scripts/task-set.sh <task-dir> stage done` (it also sets `status closed`; an abandoned task gets only `status closed`), then `scripts/ledger.sh <task-dir> cleanup "<summary line>"`, and the agents' states with `scripts/agent-set.sh … state done|stopped`.
- The task folder stays: it is the record later tasks search.
- Report in one line what was stopped, removed, queued and kept.
