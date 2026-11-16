---
name: coordinator-setup
description: >-
  Set up the coordinator on a machine, or check that it is set up: after a fresh clone, after a machine wipe,
  when a provider or model is added, or when public-check.sh or route.sh stops for missing private configuration.
---

Run `scripts/setup.sh --check` to see what is missing, then `scripts/setup.sh` to create it; both are safe to repeat.
Then follow `playbooks/setup.md`: it settles, in one question to the person, the decisions the script ends with (`decide:` lines).
Never answer those decisions yourself, and never print the private term list.
