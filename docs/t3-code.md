# What T3 Code offers the coordinator

Reviewed on 2026-11-12 and again on 2026-11-15 after the trials.
Sources: the tool schemas the app gives a thread, `orchestrator_capabilities` called from the coordinator thread, the `t3` command's own help, and the documentation at the head of the public repository (commit `55081a1f`).
The documentation is newer than the installed build, so where the two disagree the live tool list wins.
"Trial" names the step in `docs/trial-plan.md` that settled a claim, or that still has to; "untested" means documented and never exercised here.

## Confirmed live

| Fact | Evidence |
|---|---|
| The orchestration tools reach the coordinator thread. | They answer: capabilities, project list and thread list were called. |
| The coordinator writes outside its own folder. | Created and removed a file in the parent folder and in the home folder. |
| Both providers can run child tasks, across providers. | `canRunChildTask` and `canRunCrossProviderChildTask` are true for Claude and Codex. |
| Every model id in `config/models.tsv` exists in the catalog. | Listed by `orchestrator_capabilities`. |
| Effort is an option with a provider-specific name. | `effort` for Claude, `reasoningEffort` for Codex. |
| The Codex default effort is not always medium. | The default-tier model reports `default: low`. |
| A delegated task runs only in the launching thread's project. | `delegate_task` with another project's `target.projectId` is refused with `invalid_request` (trial A3, again at the sub-coordinator level). |
| A launched thread runs in any registered project and never wakes its launcher. | `t3_thread_launch` with `existing_worktree` worked; no wake, even with `delegatedFrom` (trial A4). |
| A delegated sub-coordinator keeps the wake through two levels. | It launched workers as threads, waited on them and woke the coordinator once (trial A7). |
| A wake is not always a completion. | A child that ended its turn while its own workers ran woke its launcher early. |
| A send to a running delegated child steers or queues. | `t3_thread_send` with `mode: auto` was delivered mid-turn; `t3 thread send` from the command line was queued as the child's next run. |
| Target repositories must be registered before a launch. | `t3_project_create` returned an id and left the repository's `git status` unchanged (trial A2). |
| Lineage is partial. | Delegated children carry `parentThreadId`; launched threads show `parentThreadId: null` (trial A7). The board takes the tree from `agents.tsv`. |
| Notifications are off by default. | `notificationMode` defaults to `off` and in-app notifications to `false`; only the app sets them. |
| A page drawn in the thread cannot fetch from this machine. | A `fetch` to the local server inside `html_preview` failed. |
| There is no plain REST API. | The server answers the app's page on every path; machine-readable state comes from the MCP tools, the `t3` command with `--json`, or its internal database. |
| The `t3 thread` command works from a plain terminal. | `start`, `send`, `show --json --messages <n>`, `list --project <id> --json` (top-level threads of one project only); no effort flag. |

## What it adds, by rule

**A quiet main thread and a visible fleet**

| Feature | Use | Status |
|---|---|---|
| `delegate_task` in async mode | Launches the sub-coordinator and fast workers in the coordinator's own project; the coordinator is woken when the child's turn ends. | Adopted, trial A3 |
| `t3_thread_launch` plus `t3_thread_wait` | The sub-coordinator launches workers in their repositories and waits on them. | Adopted, trials A4 and A7 |
| Child questions routed to the parent | A worker that needs an answer notifies its launcher; approvals show in the launcher's conversation. | Adopted; seen at the sub-coordinator level in A7, A8 not run on its own |
| Agents view and Working section | Delegated agents listed under their launcher; working threads folded and returned when they need attention. | Adopted, free |
| Thread and in-app notifications | An OS notification or a toast when a thread finishes, fails or needs input. The only signal for a launched thread that wakes nobody. | Recommended, developer's action |
| Thread state from `t3 thread show --json` | The live column of the board, through `scripts/live.sh`. | Adopted |
| `html_render` | A snapshot of the board inside the thread, on request; the live page is the panel. | Optional, trial A10 not run |
| Titles, pin, settle | Titles as `<KEY> · <role> · <repo name>`; coordinator pinned; finished workers settled. | Adopt |
| Recursive stop | Stopping a task stops what its child delegated. | Untested: the cancel half of A7 was not run |
| Mobile notifications | A push when an agent finishes, fails or asks. Needs T3 Connect and a sign-in. | Developer's choice |

**Machine health and cleanup**

| Feature | Use | Status |
|---|---|---|
| Bound worktrees | A worktree made under `<repo>/.claude/worktrees/` and bound with `existing_worktree`: branch and diff show in the app. | Adopted, trial A6 variant 3 |
| Managed worktrees | The runtime creates the worktree under its own folder. Used in practice; must still be recorded in `agents.tsv`. | Allowed, A6 variants 1 and 2 not evaluated |
| Worktree cleanup policies | Remove a runtime-managed worktree after its merge request merges or its thread settles; local changes protect it. Off by default, set in the app. They never reach `<repo>/.claude/worktrees/`. | Recommended for managed worktrees |
| Resource monitor | The app's diagnostics show what its processes consume over time. | Free; not checked against browsers an agent's shell starts |
| Artifact and log retention | Days to keep browser artifacts and logs; unset keeps them forever. | Recommended, developer's action |
| Project scripts | `runOnWorktreeCreate` runs a setup script in each new worktree; `runOnSettle` can free disk; `stopOnSettle` ends a dev server. | After A6 |
| Continue threads after restarts | A thread waiting on a child or a background command resumes after the app restarts. On by default. | Free |

**The account boundary**

| Feature | Use | Status |
|---|---|---|
| Provider switch per project | In the app, a provider can be turned off for one project. Turning the personal-account provider off for each company project makes rule 4 hold even against a mistake. | Recommended, developer's action |
| Permission ceiling | A child never runs with a broader mode than its parent. | Free |
| Managed policy file | Caps drivers and modes for the whole machine. Not needed while the switch above is used. | Not adopted |

**Agnostic by design**

| Feature | Use | Status |
|---|---|---|
| `t3 thread` command | Launch, read and queue a message from any terminal on the same machine. | Fallback, trial A11 not run |
| MCP for outside agents | A terminal agent signs in once and gets the thread tools, with model and effort. No delegated children there. | Fallback, trial A11 not run |
| Cross-provider children | One coordinator can start a child on any enabled provider. | Adopt |

**Phase 2 and later**

| Feature | Use |
|---|---|
| `watch_pull_request` | Wakes the thread on failed checks, passed checks, new comments or conflicts, for a self-hosted forge too. The worker thread that opened the merge request watches it; a delegated child cannot (untested). |
| Auto-merge and auto-settle | The runtime can merge when checks pass and settle the thread after. Must sit behind `hold.sh may-merge`. |
| `schedule_task` | An interval or fixed-time run with no turn open: a morning status, a cleanup sweep. A webhook trigger can start a run from a forge event; a public address needs T3 Connect. |
| Browser preview and recording | The runtime drives a browser and records it. A candidate for the demo stage. |
| `request_secret` | Asks the developer for a token in a card, never in chat. |
| Remote access and linked environments | Open the coordinator from a phone or another computer, or delegate to another machine. This reaches the records where they are, without copying them to a remote. |

## Limits to design around

- A launch into a repository needs a registered project: the sub-coordinator registers it the first time a task touches it.
- A delegated child cannot run in another project, so every agent that must wake its launcher runs in the launcher's project and reaches repositories by path.
- A delegated child receives only the task text. Nothing from the coordinator's conversation travels, which fits the verbatim rule: the brief is the whole message.
- A thread started with `t3_thread_launch` does not wake anyone when it ends: its launcher waits on it, and the handoff file is the signal.
- Notifications, auto-settle, storage cleanup and per-project provider switches have no tool: the app owns those settings.
- The app keeps conversations but prunes its internal event history after about a day and has no export. The task record stays the durable memory.
- The `t3` command cannot set effort.
- Driving Claude through the app counts against the same usage limits as a terminal session, and parallel workers spend them faster.

## Not adopted

- `create_threads`: new threads in the coordinator's own checkout. Workers belong in their repository.
- Reading the app's internal database for the board: its schema changes between releases.
- Side chats, multi-model fan-out and `ultracode`: no rule asks for them, and the last two multiply cost.
