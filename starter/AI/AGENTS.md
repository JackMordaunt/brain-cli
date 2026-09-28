# Agent configuration

Operating rules for every coding agent on this machine. Each agent reaches
this file through its own global instruction path, which `brain install`
points here. Facts live in `MEMORY.md`, lessons in `LEARNINGS.md`, prompt
craft in `TUNINGS.md`; this file is behaviour.

## Memory

This vault is shared memory for every agent. `brain locate` prints its path.
Before starting work, run `brain find <project-name>` to see what is already
known; `brain recall <terms>` searches what was said in past conversations.

Record one fact per line, in the file it belongs to:

    - **handle** (aliases) — the fact, stated once — source — YYYY-MM-DD

Search for the handle before adding a line, and update it rather than
restating it. Commit each fact on its own.
