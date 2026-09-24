# bin — the vault's own tooling

Markdown under `AI/` is canonical. Everything here is derived, disposable, or a
gate; delete `~/.local/state/brain/brain.db` at any time and `brain sync`
rebuilds it.

| file | what it is |
|------|------------|
| `brain` | query and lint the vault (`find`, `sync`, `doctor`, `log`, `lint`, `install`) |
| `hooks/pre-commit` | runs `brain lint --staged`; hard failures block the commit |
| `hooks/commit-msg` | delegates to the global hook, which a repo-local `core.hooksPath` would otherwise shadow |
| `brain-guards.sh` | shell functions that refuse commands which have cost settings before |
| `synonyms.tsv` | query expansion; the vocabulary travels with the repo |

## Install

    ~/Documents/Brain/bin/brain install

Links `~/.local/bin/brain`, points this repo's `core.hooksPath` at `bin/hooks`,
sources the guards from `~/.bashrc`, and builds the index.

## Why this shape

A CLI is not a gate — it has to be invoked, and grep always still works. Only
the pre-commit hook fires unconditionally, so the enforcement lives there and
`brain` is merely where the check's code sits.

Search ranks handle matches above body matches, because the protocol failure
this tooling exists to fix was `grep -ril review` returning 26 of 33 files.

Every query is logged with its hit count. Zero-hit queries are the synonym
backlog: they name the vocabulary the vault is missing, discovered from real
misses instead of guessed in advance. `brain log` lists them; add rows to
`synonyms.tsv` and re-run `brain sync`.

A line that does not parse is skipped, never rejected. The bullet format is
young and must not become load-bearing.
