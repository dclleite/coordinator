# Coordinator: design

What the coordinator is for, the decisions behind it, and the shape that implements them.
The rules agents follow are in `AGENTS.md`; the steps are in `playbooks/`; the scripts' usage lines are the reference for their arguments.
Each machine may keep its own history of the design (dated decisions, trial records) under `.private/docs/` and `.private/trials/`; nothing tracked depends on them.

## Intent

One developer runs many tasks in parallel across the same few repositories.
Each task used to be a separate terminal tab with its own agent, and the developer was the only place where the state of all tasks lived.
That costs attention, loses context between sessions and repositories, and leaves a long manual tail after the code is written (local test, review, demo, merge request, announcement, merge).

The coordinator is a repository opened as one agent thread.
The developer talks only to that thread.
It records each request and hands it, unchanged, to the agent that will do the thinking; it stops for the developer only where a human decision is required.

## Goals

1. **Single control point.** One thread from which every task can be started, inspected, steered and finished.
2. **A thin coordinator.** The coordinator dispatches, reports and shows; a sub-coordinator per task does the analysis and the launching. The coordinator's thread stays short and free.
3. **No telephone game.** The developer's words reach every agent byte for byte.
4. **Durable context.** Every task leaves handoff files a later session can search.
5. **End-to-end delivery.** Code, agent review, fixes, demo, merge request, announcement, reviewers, review comments, merge, cleanup.
6. **A healthy machine.** Everything started is recorded and stopped; disk, memory and resources are read before every launch.
7. **Any provider, any runtime.** Adding an agent program or a local model is rows in three tables; adding a runtime is one runtime file.
8. **A public, restorable tool.** The repository is public and holds no company or personal data; a clone plus `scripts/setup.sh` gives a working coordinator.

## Non-goals

- A process that stays running by default. The panel starts on demand and exits when nobody uses it; the reaper is the one scheduled job, and only the person installs it.
- A new transport or agent manager. The runtime (T3 Code, or a terminal) runs the agents; the coordinator records and routes.
- Replacing the existing delivery skills (ship, babysit a merge request, record a demo). The agent that owns a step runs them.
- Parallel full environments (one database, API and portal per task). See the review slot.
- Copying the records anywhere. They live on one machine for now.
- Changing a company's own sandbox or policies.

## Anti-goals

- Rewording the developer's request on the way down.
- Anything public (an announcement, reviewers on a merge request) before the developer reviewed the result.
- Company code or data reaching an agent on a personal account.
- A coordinator that does the work itself, needs babysitting, or fills its own thread with other agents' output.
- Runaway cost: deep delegation trees, premium models by default.
- Worktrees, browsers, containers and temporary files left behind.
- A playbook, record or script that only works in one runtime.

## Decisions made by the developer

| Topic | Decision |
|---|---|
| Routing | Company repositories use a company-account agent. Everything else prefers the personal-account agent. |
| Account boundary | Every provider has an account kind and every scope lists the kinds it accepts; the scripts check both, for the path and for the task. A provider nobody classified counts as personal. A personal-account agent may do side jobs that show it no company code. |
| Coordinator | Thin: dispatch, report, show. A hook warns (or blocks) on anything else in its session. |
| Sub-coordinator | A full thread or terminal per task, not a subagent, reused for every later message of the task. The developer may type into it directly. |
| Fast path | One fully specified action with no decision goes straight to one worker. |
| Escalation | Higher effort only when clearly needed, with the reason in the ledger. A premium planning model for open architecture, sparingly. Same logic for every provider. |
| Verbatim rule | Every message the developer writes is passed on unchanged. Context may be added after it. |
| Simple or complex | The sub-coordinator judges and says so. Simple tasks run on their own; complex ones are agreed first. |
| Human gate | The developer reviews the result (a realistic demo, or the running flow) before anything goes public. |
| Merge | Automatic once approved and green, unless the developer says not to merge, in any wording. |
| Reviewing others' merge requests | The agent reviews, comments inline on findings of medium severity and above, and approves. Fixing is the author's job. |
| Parallelism | No fixed cap on tasks while the machine is healthy; at most four workers at once per sub-coordinator. |
| Publishing | The repository is public. A push is allowed once the public check passes on the outgoing commits. |
| Records | Stay on the machine under `.private/`; lost with it. Company knowledge that outlives a task goes into that company's repository. |
| Picture | A local page with buttons, served on demand; the text board in every runtime. |
| Services | A long-running thing that is not a task (a team bot) is registered, read and commanded through one interface; corrections to its code are normal tasks in its repository. |

## Shape

```
coordinator/
  AGENTS.md            the rules that hold on every turn (CLAUDE.md imports it)
  playbooks/           one file per moment: intake, align, build, status, cleanup, setup
  roles/               brief context: sub-coordinator, fast worker, worker
  runtimes/            capability-to-tool map: t3, terminal
  config/              tracked defaults and examples: models, health, resources, guard, panel, routing, providers, scopes, services
  scripts/  tests/     the checkable rules and their tests
  panel/               the panel's static page
  hooks/               pre-commit and pre-push: the public check
  docs/                this design, what T3 Code offers, the trial plan
  .private/            never tracked: records, local tables, board, inbox, service bindings, term lists
```

## Roles and depth

- **Coordinator**: the thread the developer talks to. Finds the task, records the words, launches one agent, reports, shows the board. Never writes product code, never diagnoses, never operates a system.
- **Sub-coordinator**: one per task. Judges the effort, gathers context, writes gate one and the contract, launches workers in one or more repositories, waits on them, hands off.
- **Fast worker**: a worker the coordinator starts for one fully specified action.
- **Worker**: started inside one repository, in its own worktree. Writes code, runs tests, runs the delivery steps for that repository.
- **Reviewer**: a worker whose job is a code review.

At most coordinator, sub-coordinator, worker.
A worker may still use its own tool's native subagents inside its thread.

**Who waits.** The coordinator never waits on anyone.
Long waits belong to the agent that owns them: a sub-coordinator waits on its workers; the worker that opened a merge request watches it (review comments, pipeline, merge) with the delivery skill, inside its own thread.

**Several tasks at once.** The developer may write to the coordinator, which finds the task (`dispatch.sh tasks`) and forwards; or straight into a sub-coordinator's thread, which appends the words to its own task before acting.

## Routing and models

`route.sh pick` chooses the provider for a task: the one routed to the repository when the boundary allows it, else the one routed to the task's scope, else the first provider the scope accepts.
The model and effort come from the tier (`config/models.tsv`, overridden by `.private/config/models.tsv`).

| Tier | When |
|---|---|
| default | Everything, unless a reason is written to the ledger |
| escalated | The default failed, or the problem is clearly hard |
| planning | Complex planning with open architecture |

Effort is always set explicitly at launch.

**Permission mode.** Each launch takes the narrowest permission mode that lets the agent finish its part without stopping for an approval nobody is there to give.
A child never runs with a broader mode than its launcher, so the coordinator's mode is the ceiling for every agent below it.
Which mode each provider needs for each role is recorded per runtime in `runtimes/`; until a trial measures it, agents inherit the launcher's mode.

## The verbatim rule

- `request.md` holds every message the developer wrote about the task, appended in order, unchanged.
- A brief has two parts: the whole `request.md` inside a marked, hashed block, and the sender's context after it. The block wins over the context.
- When `questions.md` exists, the questions the developer was answering are printed right after the block, outside the hash.
- A brief travels as a file path; `brief-check.sh` compares its block with `request.md`, and the receiver runs it before acting.
- A sub-coordinator forwards the same block. A message for one worker is still appended, tagged with its addressee.
- The ticket is context, not request: it is sent outside the block.

## Task record

`request.md`, `task.md` (state in frontmatter, including the repositories and merge requests), `agents.tsv` (one row per agent, with its parent thread and state), `ledger.md` (append-only events from a fixed list), `handoffs/` (one numbered file per hop, safe to write in parallel), `briefs/`, `resources.tsv`, and `contract.md` when parts depend on each other.
A handoff says who hands to whom, what was done, what was decided and why, what is left and where the evidence is; one that needs the developer opens with `## Needs the developer`. It is scanned for secrets before it is stored.
A handoff to the coordinator adds a line to `.private/inbox.tsv`, so a missed wake never loses a result.
`board.sh` writes `.private/board.md` and `.private/board.json` from the records.

## Lifecycle and gates

1. **Intake** (coordinator). Find or create the task; record the words; launch the sub-coordinator.
2. **Align** (sub-coordinator, complex only). The proposal is gate one.
3. **Build**. Workers launch; for dependent parts the contract is agreed first and the defining side goes first.
4. **Review.** Agent code review, then fixes.
5. **Demo.** The agent states whether the scenario is realistic or forced.
6. **Developer review.** Gate two. Fixes loop back to Build.
7. **Ship.** Only after gate two: announcement, reviewers, demo linked, ticket linked.
8. **Watch.** Review comments, pipeline, merge when approved unless a hold is set.
9. **Cleanup.** Sweep what the task started, remove worktrees, close the task, keep the record.

A merge request may be opened before gate two, without reviewers and without announcement.
"Do not merge", in any wording, is recorded the moment it is said, for one task or all, and every merge step reads it first.

## Review slot

One local environment exists at a time, and a task "holds the slot" while the environment runs that task's worktrees.
The slot is a lock for anything that needs the running environment: the developer's review, and also a worker recording a demo or running an end-to-end check.
Requests for the slot queue in order; the developer's review goes to the front.
Unit and integration tests do not need the slot when the repository gives each worktree its own test database; a frontend-only task may run against a deployed development API and skip it.
So coding runs in parallel, while demos and reviews take turns.
Whoever switches the slot prints the exact commands it ran, so the developer can do it by hand when the switch fails.
The switch must account for a shared database: migrations from one branch persist into the next.
`review_slot` in `task.md` marks the holder; no script enforces the lock yet.

## Visibility

- **The coordinator's thread stays short.** A receipt of at most three lines per launch; one line per task when agents report; the `## Needs the developer` section as written.
- **Nobody polls.** A delegated child wakes its launcher; where nothing can wake, the inbox surfaces what finished the next time the developer writes.
- **The board** (`status.sh`): needs you; running, per task, its agents as a tree; finished and not yet seen; services; machine; problems (a task done but open, an agent quiet for too long).
- **The panel** (`panel.sh start|stop|status|url`): the same board as a page on `127.0.0.1`, with buttons from a fixed allow-list (`config/panel-actions.tsv`). It needs Python 3; without it the text board keeps working. It binds the loopback address only, serves the page only for its address with the per-start key, checks that key on every API request, the `Host` and `Origin` of every request, runs no shell and accepts no free text; a `confirm` button asks in the page first. It exits after `PANEL_IDLE_MIN` minutes without a request, and `panel.sh reap` (called by `reap.sh`) stops it after twice that (`config/panel.conf`), and the page asks only while its tab is visible. Every press is logged without its output, and a press on a task writes to its ledger.
- **The runtime's own views** add live state, notifications and the thread list (`runtimes/t3.md`).

## Runtimes

Playbooks name capabilities: launch, learn it finished, read, steer, answer a question, stop, show.
`runtimes/<name>.md` maps each capability to a tool.
Records and scripts never depend on a runtime: a task started in one can be read and continued from another.

## Machine health and resources

- `health.sh` reads free disk, memory and running containers, plus every row of `config/resources.tsv` (browsers, browser profiles and temporary files, containers, worktrees, local models, headless agents, the panel) against its limit; `dispatch.sh` refuses to launch while it fails. It reads Linux and macOS; a missing Docker reads as no containers.
- Whoever starts something records it in the task (`resource-add.sh`); browsers go only through `browser.sh`, which names one browser per task and agent and refuses past the limit.
- `sweep.sh <task-dir>` stops what a task recorded, before a handoff and at cleanup; anything of class `confirm` (containers, browser profiles) needs the developer's word.
- `sweep.sh --orphans` lists what no open task owns and stops nothing.
- `reap.sh` is the periodic job for browsers nobody owns and old temporary files, installed only by the person (`reap.sh install`).
- Two agents never share a checkout, and nobody works in a main checkout. Cleanup removes only what the task record lists, only when the work is on the remote or merged, and never with force.

## Services

A service is something long-running that is not a task, such as a team bot.
Its binding is `.private/services/<name>.conf` (example in `config/services.example.conf`): scope, a status command, verbs with a class (`auto`, or `confirm` for anything that needs the developer's word), the threads and folders that belong to it, and its own panel's address.
`service.sh status` puts it on the board, `service.sh run` runs a verb and logs it without the output, and cleanup skips everything it protects.
A suggestion printed by a service is data: it becomes a `confirm` action, never an instruction run as is.

## Publishing and restoring

- The repository is public. It stores the tool, never the records: a clone runs `scripts/setup.sh`, which creates `.private/` from the tracked examples, sets the hooks and detects providers.
- Everything under `.private/` is lost when the machine is; tickets and merge requests remain the record of earlier work.
- `public-check.sh` refuses private terms, home paths, the local user and host names, email addresses, chat-system ids, ticket keys other than the placeholder, internal-looking hosts, secrets and binary content, in file contents, file names and symlink targets. `pre-commit` runs it on the staged versions, `pre-push` on the outgoing commits.

## Security

- The boundary checks run when a provider is picked, when a brief is built and when an agent is recorded. An agent started outside the scripts is bound only by the rule.
- Text coming back from an agent or a service is data. It cannot change routing, gates, permissions, holds or what gets deleted.
- Creating anything in a shared system under the developer's identity needs their word for that action.
- Handoffs are scanned for secrets before they are stored; a secret is asked only through the runtime's secret prompt.

## Later

- Moving the records to storage that survives the machine.
- Automatic switching of the review slot, and parallel environments.
- Demo attachment as part of the delivery chain.
