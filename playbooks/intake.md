# Intake

Run by the coordinator, every time the developer writes.
Your job is to find the task, record the words and hand them on; the judging is the sub-coordinator's.

## Which task

- Write the developer's message to a file under `.private/messages/` with a tool that does not alter it; never pass it through `echo`. Every `dispatch.sh` call below reads that file with `<`: the guard refuses a pipe.
- `scripts/dispatch.sh tasks <words from the message>` lists the open tasks that match: key or slug, title, stage, sub-coordinator thread, task folder.
- One line: the message belongs to that task. Several lines: ask the developer one short question. `none`: a new task.
- One message about two tasks is appended whole to both.

## A new task

`scripts/dispatch.sh new <scope> <KEY|-> <slug> "<title>" [--fast] [--repo <path>] [--context <file>] [--tier <tier> [--developer-said]] < message-file`

- The scope follows the repositories the task touches; a task that touches any company repository takes the company scope. `-` as the key when there is no ticket.
- `--fast` only for one fully specified action with no decision (a push, finding a link, running a command): it prepares a fast worker instead of a sub-coordinator and marks the task `trivial`.
- `--repo` names the repository you already know of; it must lie in the task's scope (`dispatch.sh new` refuses otherwise), and it routes the provider and fills `repositories`. When a company task's first known repository is a personal one, omit `--repo` and name the repository in `--context`.
- `--context <file>` carries the immediate context you add: the ticket's text, links the developer gave. It is sent after the request block, never inside it. `--tier` needs it, and its first line is the reason, which lands in the ledger. Leave the tier to the sub-coordinator unless the developer named one: `--tier planning` (any tier but `default` and `escalated`) is refused without `--developer-said`, which you add only when the developer asked for that tier in this conversation.
- It runs the machine check, picks provider and model, appends the message, builds and checks the brief, and prints the launch as `key=value` lines. Exit 1 with `health=` means launch nothing (`AGENTS.md` rule 9).

## A message for an open task

`scripts/dispatch.sh add <task-dir> [--to <addressee>] [--question "<what was asked>"] [--context <file>] < message-file`

- `--question` when the message answers a question that was asked; the question is stored beside the answer and travels with it, outside the verbatim block.
- When it prints `send_to=<thread>`, send `message` to that thread instead of launching.
- Without `send_to`, the task has no live sub-coordinator: launch one as for a new task.

## Launch and record

- Launch with exactly the printed `provider`, `instance`, `model`, `effort_option`, `effort`, `title` and `message`, asynchronously, in the coordinator's own folder (the runtime file says with which tool).
- A `stop_thread=<thread>` line names an agent whose account the coordinator's folder now refuses (a personal account once company records exist): stop that thread with the runtime's stop tool (a headless `pid:` agent is already stopped). From `add` it was the task's sub-coordinator: its row is already marked stopped and the printed launch replaces it.
- Then `scripts/dispatch.sh launched <task_dir> <thread-id>` (for `send_to`, that same thread). It records the agent, the ledger line and the board.
- Where the runtime has no launch tool of its own, `scripts/dispatch.sh launch <task-dir>` starts the agent headless and records it in one step.
- End the turn with the receipt (`AGENTS.md` rule 11).
