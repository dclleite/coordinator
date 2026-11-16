# Trial plan: phase 1

This replaces the first runtime trial (stopped at its second step by a sandbox that no longer exists) and the acceptance trials that were never run.
Part A finds out how the runtime behaves; its answers are written into `runtimes/t3.md`, `runtimes/terminal.md` and `playbooks/build.md`, and the Status table says which are settled.
Part B proves the coordinator on real tasks.

## How to run it

- Run from one coordinator thread, with the developer at the app: several checks are things only the developer can see.
- Before the first step the developer names two folders: a personal repository and a company repository. Their real paths go only into the trial record. This plan calls them `<personal-repo>` and `<company-repo>`.
- The coordinator thread runs on the default tier (`scripts/model.sh claude default`). Check with the runtime before starting; a trial run on another model does not measure the real setup.
- Every launch goes through `scripts/dispatch.sh` or `playbooks/build.md`, health check included. No product code is changed in Part A.
- One record per run: `.private/trials/<date>-<part>.md`, using the template at the end. Record what was observed, not what was expected. A step that could not be run is recorded as "not run" with the reason.

**The probe.** Unless a step says otherwise, the task text is exactly:

```
Reply with three lines and nothing else: the absolute path of your working directory; the paths of the instruction files loaded in your context; the model and effort you are running with. Change nothing.
```

**The write probe:**

```
Create and delete a file named .coordinator-probe in your working directory. Then create and delete a file with the same name in <coordinator path>/.private/trials/. Reply with one line per attempt: the path and whether it worked.
```

## Status

| Step | What it settles | State |
|---|---|---|
| A0 | The sandbox is gone and the orchestration tools answer | Pass, 2026-11-12 |
| A1 | Providers, model ids, effort option names | Pass, 2026-11-12 |
| A2 | Registering a repository as a project | Pass on the tool side; the developer's view not checked |
| A3 | Delegated launch into another project | Fail: refused, a delegated child runs only in its launcher's project. Settled: delegation stays in the coordinator's project |
| A4 | Top-level launch into another project | Launch pass, wake fail (twice). Settled: a launched thread is waited on by its launcher |
| A5 | A company repository: instructions loaded, writes allowed | Handoff write into `.private/` pass; instructions loaded not recorded |
| A6 | Who creates the worktree | Variant 3 (bound worktree under `.claude/worktrees/`) pass; variants 1 and 2 not evaluated |
| A7 | Two levels: sub-coordinator and worker | Wake pass; runtime lineage partial; cancel not run. Settled: the relay through a sub-coordinator, the tree from `agents.tsv` |
| A8 | A worker's question reaches its launcher | Seen at the sub-coordinator level only |
| A9 | How much lands in the main thread | Pass for every wake measured (one to three lines) |
| A10 | The board drawn in the thread | Not run; the panel replaces it as the main picture |
| A11 | The same work from a plain terminal | Not run |
| A12 | Leaving nothing behind | Not run |
| A13 | The narrowest permission mode per role | Not run |
| A14 | The developer types into a delegated sub-coordinator's thread | Not run: a message sent from outside its parent is accepted and queued; the app's composer was not tried |
| B1 to B7 | Acceptance | Not run |

## Part A: runtime mechanics

### A0. Sandbox and tools (verified)

Evidence from 2026-11-12: a file was created and removed in the parent folder and in the home folder; no managed settings file exists; capabilities, project list and thread list answered; `scripts/health.sh` read the container count without help.
Rerun only if the account type changes again.

### A1. Capabilities (verified)

Evidence from 2026-11-12: every id in `config/models.tsv` is in the catalog; the effort option is `effort` for Claude and `reasoningEffort` for Codex; both providers can run child tasks across providers.
Rerun `orchestrator_capabilities` at the start of the trial and stop if a model id from `config/models.tsv` is missing.

### A2. Register the target projects

Do: list the projects; create one for `<personal-repo>` and one for `<company-repo>` by workspace root.
Pass when: both have a project id, and the developer sees them in the app's project picker.
Record: the tool arguments, and whether registering changed anything inside the repository (`git status` there, before and after).

### A3. Delegated launch into another project

Do: delegate the probe, asynchronously, into `<personal-repo>` with the routed provider at the default tier, effort set explicitly, titled `TRIAL · worker · <repo name>`. End the turn right after the receipt.
Pass when: the call returned at once; the coordinator was woken with the result without reading or waiting; the working directory is `<personal-repo>`; the model and effort are the ones asked for.
The developer checks: where the agent appears in the app, and whether a message can be typed to it.
Decided: a delegated child cannot run in another project.

### A4. Top-level launch into another project

Do: the same probe through `t3_thread_launch`.
Pass when: folder, model and effort are applied.
Record: where the thread appears, whether the developer can write to it, and how the coordinator learned it had finished (it is expected not to be woken).
Decides: when a top-level thread is worth losing the wake.

### A5. A company repository

Do: launch the probe, then the write probe, into `<company-repo>` with its routed provider. Before launching, confirm that `scripts/route.sh check` refuses the other provider for that path.
Pass when: the reply lists that repository's own instruction files as loaded; both writes worked.
Decides: whether workers store their own handoffs with `handoff-write.sh` (the write into `.private/` worked) or return them in the reply.

### A6. Who creates the worktree

Do, in `<personal-repo>`, three launches of the probe:

1. delegated, with `isolation: "worktree"`;
2. top-level, with `workspaceStrategy: {type: "worktree"}` from the default branch;
3. the coordinator creates a worktree inside the repository (its own script if it has one, else `git worktree add` under `.claude/worktrees/`), then launches bound to it with `existing_worktree`.

Record for each: the worktree's path and branch; whether the app shows branch and diff for the thread; whether a setup script ran; whether `git worktree remove` works afterwards from the coordinator.
Pass when: at least one variant leaves the worktree where `playbooks/build.md` wants it (inside the repository, under `.claude/worktrees/`) with the thread bound to it.
Decides: the Worktrees section of `playbooks/build.md`, and whether the runtime's cleanup policies can replace part of `worktree-cleanup.sh`.

### A7. Two levels

Do: delegate a sub-coordinator into this repository with the task "Launch one worker as a thread into `<personal-repo>` with this task: run `sleep 240`, then reply `done`. When it ends, reply `both done`." While the worker sleeps, list the threads with subagents included. Then run it a second time and cancel the sub-coordinator's task while the worker sleeps.
Pass when: the list shows the worker under the sub-coordinator under the coordinator, each with a status; the first run wakes the coordinator once, with `both done`; the cancel stops the worker too.
Decides: whether the board can take lineage and state from the runtime.

### A8. A worker's question

Do: a sub-coordinator launches a worker into `<personal-repo>` with: "Ask which of two names to use, `alpha` or `beta`, wait for the answer, then reply with the answer only."
Pass when: the coordinator is notified without polling; it relays the question to the developer in one line; the answer sent back reaches the worker; the worker replies with it.
Record: what the developer saw in the app while the question was pending.

### A9. How much lands in the main thread

Do: nothing new. For every wake in A3 to A8, note how many lines of the worker's reply entered the coordinator's context, and how many lines the coordinator wrote to the developer.
Pass when: every launch produced a receipt of at most three lines, every report at most one line per task, and no worker reply was pasted.
Decides: whether the two-line reply contract in `roles/worker.md` is enough or the runtime adds text that must be cut.

### A10. The board

Do: during A7, while the worker sleeps, draw the board in the thread: one block per task, the sub-coordinator and the worker as a tree, each with repository, model and state.
Pass when: the developer, looking only at the picture, says who is running under whom and what waits on them.
Record: what the developer wants changed in the picture.

### A11. From a plain terminal

Do, in a terminal that is not a T3 Code thread, with an agent opened on this repository:

1. `t3 status`, then launch the probe into `<personal-repo>` with `t3 thread start`, read it with `t3 thread show`.
2. Launch the probe with the agent's own headless mode from inside `<personal-repo>`.

Pass when: both replies name `<personal-repo>` as the working directory, and the model and effort actually used are known and recorded.
Record: the exact commands that worked, and which flags do not exist.
Decides: the content of `runtimes/terminal.md`, which is unverified until this step.

### A12. Leaving nothing behind

Do: settle or archive every trial thread, remove every trial worktree, confirm no probe file is left (`git status` in both repositories), run `scripts/health.sh`.
Pass when: both repositories are as they were, and `git worktree list` in each shows no trial worktree.

### A13. The narrowest permission mode

Do: launch the probe and the write probe as a sub-coordinator and as a worker with each runtime mode narrower than the launcher's, one at a time.
Pass when: for each role, the narrowest mode in which the agent finishes without an approval request is known.
Decides: the permission mode written into `runtimes/t3.md` for each role.

### A14. Typing into a sub-coordinator

Do: while a delegated sub-coordinator runs, the developer opens it from its link and types a message in the app's composer.
Pass when: the message reaches it, it appends the words with `request-add.sh`, and the coordinator is woken once at the end.
Decides: whether the developer can talk to a sub-coordinator without going through the coordinator.

## Part B: acceptance

Before B1: the settled Part A decisions are in the runtime files and `playbooks/build.md` (done), and `scripts/status.sh` prints the tree.

- **B1. One repository.** The developer gives a small real task. Pass when: a record exists with the message byte for byte in `request.md`; one worker ran in that repository, in its own worktree, with the routed provider at the default tier; the brief it received passes `brief-check.sh`; a handoff came back; the board showed the task while it ran; the developer opened no other terminal.
- **B2. Two repositories.** A task with a backend change and a consumer change. Pass when, in addition: `contract.md` existed before either worker started coding; both workers received the same request block; the board showed both under one task.
- **B3. Hold and health.** During a trial the developer says not to merge, in their own words: `hold.sh may-merge` exits 1 afterwards. With `HEALTH_DISK_FREE_GB=5` exported, the coordinator refuses to launch and names the disk threshold.
- **B4. A quiet thread.** While B1 runs, the developer brings a second, unrelated task. Pass when: the coordinator took it without waiting for the first; across B1 and B2 no receipt passed three lines and no report passed one line per task.
- **B5. Private data.** After B1 and B2: `scripts/public-check.sh` exits 0, `git status` shows no file from `.private/`, and no tracked file names either repository.
- **B6. Another terminal.** Open a plain terminal on this repository and ask what is running. Pass when: the answer matches the board, from the records alone.
- **B7. Cleanup.** Close one trial task: its worktrees are removed or queued, the record stays, the board no longer lists it.

Anything that fails or needs the developer becomes input for the phase 2 plan.

## Record template

```
# Trial <part>, <date>

Runtime and version:
Coordinator model and effort:
<personal-repo> =
<company-repo> =

## <step id>
Tool and arguments:
Observed:
Seen by the developer:
Verdict: pass | fail | not run (reason)
Decision:
```
