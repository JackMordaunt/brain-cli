# brain

A CLI for a markdown notes vault that agents can search.

Markdown is canonical. The SQLite index is disposable: delete it at any time and
`brain sync` rebuilds it. Nothing the CLI stores is authoritative, so the vault
stays readable, diffable and yours.

## Two repositories

This repository is the tool. Your notes are a separate repository — private,
committed on your own schedule, never mixed with the CLI's history.

```
brain install ~/path/to/your/vault
```

That records the vault in `~/.config/brain/vault`, links `brain` onto PATH,
points the vault's git hooks at this checkout, and builds the index.

A single checkout holding both still works: if the directory above `bin/` has an
`AI/` in it, that is the vault too.

## Use

```
brain find <terms...>   search bullets; handle matches rank above body matches
brain locate            absolute path to the vault, for agents and scripts
brain sync              rebuild the index
brain doctor            what is stale, thin, oversized, duplicated or orphaned
brain log               zero-hit queries — the synonym backlog
brain lint [--staged]   check bullet form; hard failures block a commit
brain secrets           scan for credentials (gitleaks, with a built-in fallback)
```

## The vault's shape

Three core files — `AI/MEMORY.md`, `AI/LEARNINGS.md`, `AI/TUNINGS.md` — hold
bullets of one fact each:

```
- **handle** (aliases: what a future searcher might type) — the fact — source — YYYY-MM-DD
```

`brain lint` enforces the trailing date and refuses a bullet carrying a literal
credential. Everything else in the vault is prose, indexed line by line so
handoffs and longer notes are findable too.

`testdata/vault` is a fixture of exactly this shape; `just test` runs the whole
suite against it, so the tests pass on a machine with no notes at all.

## What is in here

| file | what it is |
|------|------------|
| `bin/brain` | the CLI |
| `bin/hooks/pre-commit` | runs `brain lint --staged`; hard failures block the commit |
| `bin/hooks/commit-msg` | delegates to the global hook, which a repo-local `core.hooksPath` would otherwise shadow |
| `bin/hooks/post-commit` | resyncs the index after every commit |
| `bin/shims/` | PATH shims that refuse commands the vault records as traps |
| `bin/synonyms.tsv` | query expansion; the vocabulary ships with the CLI |
| `testdata/vault/` | the fixture the test suite runs against |

## Requirements

`bash`, `git`, and a `sqlite3` built with FTS5. `gitleaks` is optional and
improves `brain secrets`.

## Development

```
just build     syntax-check every script
just test      run against the fixture vault
just install   bind this machine to a vault
```
