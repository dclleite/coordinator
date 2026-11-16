# Runtime: any other terminal

You are in this runtime when `T3CODE_THREAD_ID` is not set: a plain terminal session of any agent, opened on this repository.
The records, the scripts and every rule in `AGENTS.md` work the same; only launch, wait, read and steer change.
Start the coordinator with `COORD_ROLE=coordinator` in its environment, so the guard checks that session and no other.
Nothing on this page has been exercised end to end by an agent (trial A11); `scripts/dispatch.sh launch` and `scripts/live.sh` are covered by tests.

## Headless agents: `dispatch.sh launch`

| Capability | How |
|---|---|
| Launch | After `dispatch.sh new` or `add`, `scripts/dispatch.sh launch <task-dir>`. It starts the agent in the background, detached from the terminal and without `COORD_ROLE`, `T3CODE_THREAD_ID` or `CLAUDE_CODE_SESSION_ID`, with the provider's `launch` template from `.private/config/providers.tsv` (`{dir}`, `{model}`, `{effort}`, `{brief}` filled), records it as thread `pid:<n>` plus a resource of kind `agent-runs` and the process's start time in `runs/NN-<role>.start`, and prints `thread=` and `log=`. A provider whose template is `-` exits 2 and nothing starts. |
| Read | The agent's output is `<task-dir>/runs/<NN>-<role>.log`; its handoff lands in `handoffs/` as everywhere. |
| Learn it finished | Nothing wakes the coordinator: `scripts/status.sh` shows the inbox the next time the developer writes or asks. `scripts/live.sh pid:<n>` says `running` or `ended`. |
| Steer | A headless agent reads no further messages. When `dispatch.sh add` prints `send_to=pid:<n>`, wait until it has ended, then `dispatch.sh launch <task-dir>` starts a new one with the full brief and marks the old one stopped. |
| Stop | `scripts/sweep.sh <task-dir>` stops the task's running `agent-runs`. |

`dispatch.sh launch` starts only what `dispatch.sh` prepared: a sub-coordinator or a fast worker.
A sub-coordinator starts each worker by hand from the same `launch` template, with the worker's worktree as `{dir}`, in the background as its own process group (`set -m`, so `live.sh` and the sweep see it), output under `<task-dir>/runs/`, and records it with `agent-add.sh` (thread `pid:<n>`) and `resource-add.sh <task-dir> agent-runs <n>`, then `scripts/live.sh --mark <task-dir> pid:<n>` right after the start, or `live.sh` reads it as ended and the sweep never stops it.

## A sub-coordinator the developer can type into

The developer works on several tasks at once, so each sub-coordinator that the developer may talk to gets its own named terminal: a terminal tab, or a multiplexer window (`tmux new-window -n <title>` inside one coordinator session).

- Launch: in that window, start the provider's interactive agent in the coordinator's folder, without `COORD_ROLE`, with the model and effort `dispatch.sh` printed and its `message=` line as the first prompt. Then `scripts/dispatch.sh launched <task-dir> <window-name>` (no spaces in the name).
- The developer attaches (`tmux attach`, then selects the window by its title) and types; the sub-coordinator appends each such message with `request-add.sh` before acting on it.
- The coordinator forwards a message with `dispatch.sh add <task-dir>`; with `send_to=<window-name>`, the `message=` line goes into that window. A multiplexer's send command is not on the guard's list, so the developer pastes the line, or the guard's warning is accepted for that one call.
- `scripts/live.sh <window-name>` prints `unknown`: the board knows the agent only from the records.

## The T3 Code server is running, from outside

The `t3` command reaches the same threads from a terminal (`t3 status` checks it): `t3 thread start <project id or path> - --provider <instance> --model <model> --title "<title>" --json < <message-file>` launches, `t3 thread show <id> --json --messages <n>` reads, `t3 thread send <id> - < <message-file>` queues a message as the thread's next run, `t3 thread list --project <id or path> --json` lists one project's top-level threads.
It has no effort flag: the thread takes the project's default model and effort, so set that first and record the effort you verified.
Nothing launched this way wakes the coordinator.

## Showing what runs

`scripts/status.sh` prints the board as text; `scripts/panel.sh start` serves the same board as a page on this machine.
