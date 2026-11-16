# Setup

Run by any agent the person opens on this folder after a fresh clone or a wiped machine; for a new provider later, by a fast worker the coordinator starts (the coordinator's guard allows it no other script).
`scripts/setup.sh` already did everything a machine can tell on its own; this is the part only the person can settle.

## 1. Run the script

Run `scripts/setup.sh`, and `scripts/setup.sh --check` after it.
Keep its `decide:` lines: they are the agenda below.
It runs `scripts/providers.sh detect --write`, which adds the agent programs it finds (copies off PATH included) to `.private/config/providers.tsv` with account `unknown`; an existing row's account is never changed. `detect` only notes local model servers that already answer; it never starts one.
A line `<tool>: found at <path>, not on PATH` ends with the line to add to the shell profile: pass it to the person, never edit the profile.
If it says the git config could not be written, the person runs the command it printed; do not work around it.

## 2. Ask once

Put every open decision in one message, each with what the script found and your default, so the person can answer in one reply.

- **Which folders are company.** One row per folder in `.private/config/routing.tsv`: path, provider, scope.
  Every non-`*` row must have three tab-separated fields and name a folder that exists (`~` is expanded); otherwise every `route.sh` call stops with the line number, and `scripts/setup.sh --check` prints that line.
  Ask for the folders; never infer a company from a path or a remote.
- **The account of each provider.** For each row of `.private/config/providers.tsv` whose account is `unknown`: `company`, `personal` or `local`. Say that an unanswered provider counts as `personal`, so it can never enter a company folder by omission.
- **Launch templates.** A provider whose `launch` column is `-` cannot be started by `dispatch.sh launch` in a plain terminal; propose the template from its `--help`, never a guessed flag.
- **The reaper.** Whether to install the one scheduled job: `scripts/reap.sh install` (on Linux it prints the cron line to add), `scripts/reap.sh --dry-run` first to show what it would do, `scripts/reap.sh uninstall` to remove it. Its ages and limits are in `config/health.conf`. Never install it without the person's yes.
- **What a scope accepts.** Only when the routing table has a scope other than the ones in `config/scopes.example.tsv`: which account kinds `.private/config/scopes.tsv` should let in.
- **The private terms.** Only while the script asks for them: it stops once the list holds a term it did not discover itself. The script seeded what it could discover and never printed it. Ask for what it cannot know: the company's names, people, repository names, internal hosts and the ticket prefix. They go one per line into `.private/sensitive-terms.txt`.

Do not show the seeded terms back, and do not read company code to find terms.

## 3. Write the answers

Write each answer to the file named above, then run `scripts/setup.sh --check` and `scripts/public-check.sh`; both must exit 0.
`scripts/providers.sh list` shows the result.
A provider nobody tuned needs only a `default` row in `.private/config/models.tsv`, with a fifth column `untuned`: `model.sh` derives `escalated` and `planning` from it and warns until the person confirms the rows.
A local model is a provider of kind `local`: an agent program pointed at a server on this machine. A loaded model holds memory: it is the `local-models` row of `config/resources.tsv`.
If the runtime can list its own providers, models and effort names, compare them with `providers.tsv` and mention a difference in the same reply; the account column stays the person's.

## 4. Say what is lost

On a wiped machine, say once that `.private/` was not restored: task records, handoffs, the board and the local tables start empty, and tickets and merge requests remain the record of earlier work.
