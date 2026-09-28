# brain

A CLI for a markdown notes vault that agents can search.

Markdown is canonical. The SQLite index is disposable: delete it at any time and
`brain sync` rebuilds it. Nothing the CLI stores is authoritative, so the vault
stays readable, diffable and yours.

## Two repositories

This repository is the tool. Your notes are a separate repository — private,
committed on your own schedule, never mixed with the CLI's history.

```
brain install [~/path/to/your/vault]
```

That records the vault in `~/.config/brain/vault`, puts `brain` on PATH,
points the vault's git hooks at this checkout, and builds the index. The
vault is the path given, else `BRAIN_VAULT`, else the one already recorded,
else `~/Documents/Brain`, which is created as a new git repository with a
starter `AI/` if it does not exist. Nothing is searched for. Run
`brain install <path>` again to move to another vault.

Without a checkout, an installer fetches the released binary for the machine
it runs on, checks its sha256, and puts it in `~/.local/bin`. On Linux and
macOS:

```
curl -fsSL https://mordaunt.dev/code/brain-cli/install.sh | sh
```

On Windows, in PowerShell:

```
irm https://mordaunt.dev/code/brain-cli/install.ps1 | iex
```

Both end by running `brain install`, so a machine with no vault gets one at
`~/Documents/Brain`. To bind an existing vault instead, set `BRAIN_VAULT`, or
pass the path to the shell installer with `sh -s -- <vault>`.

`BRAIN_VERSION` pins a release tag and `BRAIN_BINDIR` picks the directory.
Releases are built by `.github/workflows/release.yml` on a `v*` tag.

A release binary keeps itself current. `brain update` fetches the latest
release, verifies the Ed25519 signature on its checksum file with the key
compiled into the binary, checks the download against that file, keeps the
old binary as `brain.old`, swaps the new one in and runs it. Once a day, when
run at a terminal, `brain` says on stderr that an update exists; it never
downloads on its own, and hooks, agents and pipes never see the notice.
`BRAIN_NO_UPDATE=1` silences it. `brain version` prints the build's tag, or
`dev` for a local build, which never updates itself.

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

The vault's vocabulary is `AI/synonyms.tsv`: tab-separated `term` and
`expansion` rows under a header, one expansion per row. `find` widens each
query term with its rows, so `systemd` can also match a bullet that says
`user unit`. The file is reloaded whole on every `sync`; the misses `brain
log` lists are the backlog for editing it. A vault without the file has no
expansion.

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
| `.gitleaks.toml` | the default ruleset `brain secrets` applies |
| `starter/` | the vault `brain install` creates when none exists |
| `testdata/` | the fixture vault and transcripts the test suite runs against |

The hooks and the gitleaks ruleset are compiled into the binary. `brain
install` writes the hooks under `~/.config/brain/hooks` with the binary's own
path inside them, so a release binary needs no checkout and a hook runs
whatever PATH git was started with. Edit the files here; a rebuild picks them
up.

## Requirements

To run: one static binary. SQLite with FTS5 is linked in; nothing is needed on
PATH. `git` is used by `brain lint --staged`, `brain secrets`, and the hooks.
`gitleaks` is optional and improves `brain secrets`.

To build: [Odin](https://odin-lang.org) and the
[jm collection](https://mordaunt.dev/code/jm), pinned as the `jm`
submodule. `just build` fetches it and builds its SQLite archive when either
is missing; `JM=<path>` builds against another checkout instead.

On Windows, `brain install` links the binary into `~/.local/bin` (Developer
Mode) or copies it; add that directory to the user PATH for PowerShell and
cmd. Git Bash users get it from `.bashrc`. Re-run install after a rebuild
when the binary was copied.

## Development

```
just build     debug binary with the debug allocator and ASan -> build/debug
just release   optimised binary                                -> build/release
just test      the package's tests against the fixture vault
just check     type-check for linux, darwin and windows
just install   bind this machine to a vault
```
