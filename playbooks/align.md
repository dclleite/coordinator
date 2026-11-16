# Align (gate one)

Run by the sub-coordinator, for a task it judged complex.
Nothing that builds is launched until the open decisions are settled with the developer.

- Set `stage align` with `scripts/task-set.sh`.
- Gather what the decisions need: read the ticket, the repositories, earlier task records. Research workers may run now (they change nothing); builders may not.
- Write the proposal as your handoff to the coordinator, opening with `## Needs the developer`: the open decisions, most consequential first, each with your recommendation. `scripts/report.sh` shows that section to the developer as written and sets `needs_developer`.
- The answers arrive as a new brief pointer from the coordinator, or typed into your thread (append those with `scripts/request-add.sh <task-dir> --question "<the question>"`). Either way the question is stored in `questions.md` and `brief-build.sh` prints it beside the answers in every later brief.
- When parts depend on each other (backend and portal, backend and mobile app), write `<task-dir>/contract.md`: the interface both sides build against, and which side defines it. When the repositories already publish their interface (an OpenAPI package, a schema), the contract is the change to it; the side that owns it goes first and consumers receive it as written.
- An open architecture is not by itself a reason for the `planning` tier: that tier is the developer's to ask for. Without their word, plan on `default`, or `escalated` with its reason in the ledger.
- When everything is settled, set `needs_developer no`, write `scripts/ledger.sh <task-dir> gate "gate one: <summary>"`, and go to `playbooks/build.md`.
