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

That records the vault in `~/.config/brain/vault`, puts `brain` on PATH,
points the vault's git hooks at this checkout, and builds the index.

Without a checkout, `install.cmd` fetches the released binary for the machine
it runs on, checks its sha256, and puts it in `~/.local/bin`. The one file is
both a shell script and a batch file, so the command is the same everywhere
once it is on disk:

```
sh install.cmd ~/path/to/your/vault      # Linux, macOS, Git Bash
install.cmd C:\path\to\your\vault        # cmd or PowerShell
```

`BRAIN_VERSION` pins a release tag and `BRAIN_BINDIR` picks the directory.
Releases are built by `.github/workflows/release.yml` on a `v*` tag.

A single checkout holding both still works: if the checkout has an `AI/` in
it, that is the vault too.

## Use

```
brain find <terms...>   search bullets; handle matches rank above body matches
brain recall <terms...> search agent transcripts (see below)
brain locate            absolute path to the vault, for agents and scripts
brain sync              rebuild the index
brain doctor            what is stale, thin, oversized, duplicated or orphaned
brain log               misses that still miss, and who is asking
brain lint [--staged]   check bullet form; hard failures block a commit
brain secrets           scan for credentials (gitleaks, with a built-in fallback)
```

## Recall — searching transcripts

`brain find` answers what was concluded and is still true. `brain recall`
answers what was actually *said*, across your agents' transcripts:

```
brain recall --enable claude      # opt in, once, per agent
brain recall <terms...>           # ranked snippets, newest agent formats included
brain recall --full <id>          # one turn in full
brain recall --sync               # full re-ingest; normally automatic
brain recall --sources            # which adapters exist and which are on
```

Transcripts are not vault content. They are machine-written, never committed,
and their formats belong to other people's programs — so they live in their own
database (`transcripts.db`), behind their own command, and nothing about them
reaches the markdown.

A turn is identified by the agent's own id, so a session resumed into a new file
re-inserts nothing. Results are snippets, not whole turns: ten hits cost about
half a kilobyte rather than the ~20 KB the full bodies would.

**A recall hit is evidence of what was said, not of what is true.** A claim
retracted three turns later reads exactly like a sound one. Vault bullets and
the current code outrank it.

The current session is excluded by default, so an agent asking whether it has
discussed something does not find itself. A conversation that was resumed into
a second file can still surface its earlier half; `--all` turns the filter off.

### Adding an agent

One `Adapter` in `brain/adapters.odin`: a `list` proc that names every
transcript on the machine and an `emit` proc that turns one transcript into
`Turn` values (id, timestamp, role, session, title, cwd, body). Add it to
`ADAPTERS` and `brain recall --enable <name>` knows it.

A transcript with no title is a headless API run, not a conversation, and should
emit nothing — that is the difference between every file on disk and the few
worth recalling.

## The vault's shape

Three core files — `AI/MEMORY.md`, `AI/LEARNINGS.md`, `AI/TUNINGS.md` — hold
bullets of one fact each:

```
- **handle** (aliases: what a future searcher might type) — the fact — source — YYYY-MM-DD
```

`brain lint` enforces the trailing date and refuses a bullet carrying a literal
credential. Everything else in the vault is prose, indexed line by line so
handoffs and longer notes are findable too.

Every `find` is logged with its entry count and its caller. Claude Code is
recognised from its own environment; any other agent sets `BRAIN_CALLER` and
`BRAIN_SESSION` so `brain log` can say who asks and how often. A zero-hit query
is a backlog item only while it still misses: `brain log` re-runs each one and
sets aside those a later edit answered. `brain doctor` uses the same log to name
bullets returned often enough that a gate or a project file should carry them.

`testdata/vault` is a fixture of exactly this shape; `just test` runs the whole
suite against a copy of it, so the tests pass on a machine with no notes at all.

## What is in here

| file | what it is |
|------|------------|
| `main.odin` | the entry point |
| `brain/` | the CLI: vault scanner, index, every subcommand, and their tests |
| `bin/hooks/pre-commit` | runs `brain lint --staged` and `brain secrets --staged`; hard failures block the commit |
| `bin/hooks/commit-msg` | delegates to the global hook, which a repo-local `core.hooksPath` would otherwise shadow |
| `bin/hooks/post-commit` | resyncs the index after every commit |
| `bin/shims/` | PATH shims that refuse commands the vault records as traps |
| `bin/synonyms.tsv` | query expansion; the vocabulary ships with the CLI |
| `.gitleaks.toml` | the default ruleset `brain secrets` applies |
| `testdata/` | the fixture vault and transcripts the test suite runs against |

## Requirements

To run: one static binary. SQLite with FTS5 is linked in; nothing is needed on
PATH. `git` is used by `brain lint --staged`, `brain secrets`, and the hooks.
`gitleaks` is optional and improves `brain secrets`.

To build: [Odin](https://odin-lang.org) and the
[jm collection](https://github.com/jackmordaunt/jm), checked out beside this
repository or named by `JM=<path>`, with its SQLite archive built
(`just sqlite` there).

On Windows, `brain install` copies the binary to `~/.local/bin`; add that
directory to the user PATH for PowerShell and cmd. Git Bash users get it from
`.bashrc`. The recorded tool path keeps the copy pointed at this checkout, so
`git pull` needs no re-install; a rebuild does.

## Development

```
just build     debug binary with the debug allocator and ASan -> build/debug
just release   optimised binary                                -> build/release
just test      the package's tests against the fixture vault
just check     type-check for linux, darwin and windows
just install   bind this machine to a vault
```
