# Build: launching and steering workers

Run by the sub-coordinator. Tool names are in the runtime file (`AGENTS.md` rule 15); this playbook says what must happen.
Scripts are under `scripts/` of the coordinator's folder, where you run.

## Launch a worker

The order matters: each step reads what the one before produced.

1. Health: `scripts/health.sh`. Stop on exit 1. At most four workers running at once.
2. Provider: `scripts/route.sh pick <task-dir> <repo>`; it already checks the repository and the task's scope, and a refusal is final. Model and effort: `scripts/model.sh <provider> default`.
3. Context: a file starting from `roles/worker.md`, filled in. Name `ticket.md` and `contract.md` by path when they exist.
4. Brief: `COORD_SENDER="the sub-coordinator" scripts/brief-build.sh --for <provider> <task-dir> <context-file> > <task-dir>/briefs/<NN>-<role>.md`, then `scripts/brief-check.sh <task-dir> <brief-file>`. `questions.md` is added by the script; do not paste it.
5. Launch asynchronously in the target repository, in the worker's own worktree, with the provider, model and effort from step 2, the narrowest permission mode the work allows, and a title `<KEY> · <role> · <repo name>`. The launch message is: `Your brief is the file <absolute path>. Read it whole before anything else, run <coordinator>/scripts/brief-check.sh <task-dir> <that file> and stop if it fails, then do what it says.`
6. Record: `scripts/agent-add.sh <task-dir> worker <provider> <model> <effort> <repo> <worktree|-> <branch|-> <thread-id> <your thread id>`, then `scripts/ledger.sh <task-dir> launch "<role> in <repo>"`. `agent-add.sh` repeats the boundary checks.

## Worktrees

Two agents never share a checkout, nobody works in a repository's main checkout, and two workers never change the same files at the same time.
The worktree is created before the launch under `<repo>/.claude/worktrees/<name>` (with the repository's own script where its instructions name one) and the worker is bound to it, or the worker creates its own and reports the path.
Confirm the path with `git -C <repo> worktree list`, then `scripts/agent-set.sh <task-dir> <thread-id> worktree <path>` and `… branch <name>`. A worktree nobody recorded is invisible to cleanup. Whoever creates it also runs `scripts/resource-add.sh <task-dir> worktrees <path>`: cleanup removes only a worktree recorded as made.

## Order of work

Independent parts launch together.
Dependent parts follow `contract.md`: the side that defines the interface starts first, and the consumer is launched with the contract.

## Wait and steer

- Wait on your workers with the runtime's wait capability; never poll. A wake is not a completion: the worker's handoff file is.
- A new message for one worker: append it with `scripts/request-add.sh <task-dir> --to <role-name> < message-file` (the developer's words only), build and check a fresh brief, and send its path to that worker's thread.
- Do not answer a worker's question from your own guess when the answer changes what gets built: it goes into your handoff under `## Needs the developer`.
- State changes: `scripts/agent-set.sh <task-dir> <thread-id> state waiting|done|failed|stopped`.
- Escalate the tier only after the default failed or the problem is clearly hard: `scripts/ledger.sh <task-dir> escalation "<tier>: <reason>"` first.

## When a worker reports

- A worker stores its own handoff with `scripts/handoff-write.sh` and replies with the path and at most two lines. One that cannot write ends its reply with the handoff between `HANDOFF BEGIN` and `HANDOFF END`: save that text unchanged to a file and store it with `scripts/handoff-write.sh <task-dir> <role-name> sub-coordinator < file`. The script refuses what `scripts/secret-scan.sh` flags as a secret; tell the worker to resend without it.
- Mark the worker `done` (or `failed`), then run `scripts/sweep.sh <task-dir>`: it stops what the task recorded and left alive. Containers and browser profiles need `--confirmed`, which only the developer gives.
- Update `stage`, `waiting_on`, `repositories` and `merge_requests` with `scripts/task-set.sh`.

## Review, demo, watch

These run inside the task, with the repository's delivery skills, by the agent that owns the step: a reviewer worker for the review, the worker that opened a merge request for its watch.
The review environment is one slot shared by every task (`docs/design.md`, Review slot): take it, say so in the ledger, give it back.
Nothing public before gate two; every merge step runs `scripts/hold.sh may-merge <task-dir>` first.

## Your handoff

When every part is done, or one is blocked on the developer, write your handoff to the coordinator (`roles/sub-coordinator.md`, Reporting).
