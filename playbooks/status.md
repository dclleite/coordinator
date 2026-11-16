# Status

Run by the coordinator, when the developer asks what is running and at the start of every session, before anything else.
It is answered from the records plus a live look, never from memory of the conversation.

## At the start of a session

- Make this session the one the guard checks: in a T3 Code thread run `scripts/guard.sh claim` once; in a plain terminal the coordinator was started with `COORD_ROLE=coordinator` in its environment.
- Then answer as below.

## What is running

- `scripts/status.sh` prints what finished since last time (`report.sh`) under `## Finished, not yet seen`, and nothing there when nothing did, then rebuilds and prints the board (`board.sh`): needs you; running, per task, its agents as a tree; finished and not yet seen; services; machine; problems. `--live` adds each running agent's state from the runtime (`scripts/live.sh`); `unknown` means the runtime could not be asked. An agent recorded before agents had a state shows `state not recorded`.
- `scripts/report.sh` alone says one line per new handoff and the `## Needs the developer` section word for word; say that and nothing more. `--peek` reads without marking. `nothing new` means nothing came in.
- Answer in the board's order, one line per task; details only when asked.
- A service whose state is not `ok` goes under what needs the developer (`scripts/service.sh status --all` shows them alone).
- The machine section is one line when every health reading is ok (their number, free disk, free memory); otherwise it lists only the readings that are not ok, each against its limit, then the count of the ones that are. What no open task owns (orphans) is listed in the board's machine section; when a kind is over its limit, a fast worker runs `scripts/sweep.sh --orphans` for the full list, which stops nothing. Fold stopping orphans into the one aggregated question; the developer's go is carried out by a fast worker or by the panel's buttons.
- A problem line (a task done but still open, an agent with no activity for longer than `STALE_AGENT_MIN`) goes to that task's sub-coordinator with `dispatch.sh add`, or to the developer when it needs them.

## A picture

- The panel shows the same board in a browser page, with buttons: `scripts/panel.sh start` prints its address with its key (`panel.sh url` prints it again; the page refuses an address without it) (it starts nothing when one is already running), `panel.sh status` says whether it runs, `panel.sh stop` ends it. It stops by itself when nobody looks at it, and the reaper stops one that did not.
- Where the runtime can draw a page in the thread, it may show the board instead; in plain text, print `.private/board.md`.
