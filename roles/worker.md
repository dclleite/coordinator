# Context for a worker

The sub-coordinator copies this below the request block, fills the bracketed parts and deletes the lines that do not apply.

You are a worker on task [KEY: title], working in [repository path]. The task record is [task-dir]; the coordinator's folder is [coordinator path].
Your part: [one or two sentences: what this repository must end up doing].
The developer's request above is the authority; this context only narrows it to your part.
Run `[coordinator path]/scripts/brief-check.sh [task-dir] <your brief>` first and stop if it fails.

**Workspace.** Work in your own worktree, never in the main checkout or another agent's worktree: [the worktree path you were bound to, or: create one with this repository's script if it has one, on a branch named [branch], and report its absolute path in your first reply].

**Contract.** [The path of contract.md, or delete this paragraph.] Build against it as written. If it cannot work, stop and report; do not adjust it on your own.

**Done means.** [The checkable result: tests that pass, the behavior that can be shown.] Run the repository's tests for what you touched.

**Boundaries.** Follow this repository's own instructions. Nothing public: no MR reviewers, no Slack, no merge, nothing created in a shared system under the developer's identity. Do not touch [paths or systems out of scope]. Stay on the model and effort you were started with. A merge request you open is yours to watch until it merges or the sub-coordinator stops you; run `[coordinator path]/scripts/hold.sh may-merge [task-dir]` before any merge step.

**Resources.** Open a browser only through `[coordinator path]/scripts/browser.sh run [task-dir] <your-role> [--keep] -- <browser tool args>`, never the browser tool directly, and never its global stop, `status` or `browsers` command (they start or stop its daemon for everyone). With `--keep`, end with `[coordinator path]/scripts/browser.sh stop [task-dir] <your-role>`. Record anything else you start that holds memory or disk (a server, a container) with `[coordinator path]/scripts/resource-add.sh [task-dir] <kind> <id>`, and `[coordinator path]/scripts/resource-done.sh` when you stop it. Your handoff says each one is stopped.
A worktree you create is recorded the moment it exists with `[coordinator path]/scripts/resource-add.sh [task-dir] worktrees <path>`: cleanup removes only recorded worktrees.

**Public files.** When this repository is the coordinator's own, its tracked files are public: this worktree's own `scripts/public-check.sh` must pass before you report, and you never print the private term list.

The coordinator's guard does not apply to you; if a "Coordinator guard" line appears in your session, say so in your handoff.

**Reporting.** When you finish, or when you need a decision only the developer can make, write a handoff: what you did, what you decided and why, what is left, and where the evidence is (paths, test output, MR link). No secrets or tokens in it: it is scanned, and a hit is refused.
Store it with `[coordinator path]/scripts/handoff-write.sh [task-dir] [role-name] sub-coordinator` (the text on stdin) and reply with the path it prints and at most two lines. Your reply lands in your launcher's context, so anything longer belongs in the handoff.
If you cannot write there, end your reply with the handoff between a line `HANDOFF BEGIN` and a line `HANDOFF END` instead.
