<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/hero-dark.svg">
    <img src="branding/hero-light.svg" alt="brainfold" width="560">
  </picture>
</p>

<p align="center"><b>brainfold</b> is a notes vault your AI agents can search.<br>Plain markdown. One binary. Nothing to host. The command is <code>brain</code>.</p>

## Install

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-linux-dark.svg">
  <img src="branding/badge-linux-light.svg" alt="Linux" height="36">
</picture>

```sh
curl -fsSL https://mordaunt.dev/code/brainfold/install.sh | sh
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-macos-dark.svg">
  <img src="branding/badge-macos-light.svg" alt="macOS" height="36">
</picture>

```sh
curl -fsSL https://mordaunt.dev/code/brainfold/install.sh | sh
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-windows-dark.svg">
  <img src="branding/badge-windows-light.svg" alt="Windows" height="36">
</picture>

```powershell
irm https://mordaunt.dev/code/brainfold/install.ps1 | iex
```

Each one downloads the release for your machine, checks its hash, puts
`brain` in `~/.local/bin`, and creates a vault at `~/Documents/Brain` if you
do not have one yet.

Already keep notes somewhere? Point at them instead:

```sh
BRAIN_VAULT=~/notes sh install.sh     # at install time
brain install ~/notes                 # any time after
```

## Still just a folder of markdown

The vault is an ordinary directory of `.md` files. Obsidian opens it. `git`
versions it. `grep` works on it. Nothing brain adds changes that.

What a bare folder does not give an agent, brain layers on top:

- **Ranked search, sized for a context window.** `brain find <terms>` returns whole bullets, best handle first, and nothing else. No file paths to open next, no surrounding prose.
- **A vocabulary.** `AI/synonyms.tsv` widens each query term, so `systemd` also finds the bullet that says `user unit`.
- **Bullets that stay well formed.** `brain lint` runs in a pre-commit hook: one fact, a source, a date. `brain secrets` refuses a credential.
- **A record of what was asked.** Every `find` is logged. `brain log` shows the misses that still miss. `brain doctor` shows what is stale or duplicated.
- **Memory of what was said.** `brain recall <terms>` searches your agents' own conversation logs, as ranked snippets.
- **A cache, not a database.** The SQLite index is disposable. Delete it, `brain reindex` rebuilds it from the markdown.
- **One binary that keeps itself current.** `brain update` fetches a signed release. It never updates unasked.

## What a search costs

Measured on a working vault of 115 files, 826 KB, as an agent sees it: one
line per hit with the handle, the fact and the date, since the aliases and
source only cost context. A terminal gets the line as written. The grep
columns search for the query's first word, the way an agent without an
index would start. Tokens are bytes over four.

| query | `brain find` | `grep -ri` over `AI/*.md` | `grep -ri` over the vault |
|-------|-------------:|--------------------------:|--------------------------:|
| `hyprland window rule` | 1.5 KB, ~370 tokens | 4.3 KB | 8.1 KB |
| `jm hot-watch` | 1.2 KB, ~300 tokens | 27.6 KB | 72.5 KB |
| `sqlite fts5` | 1.5 KB, ~370 tokens | 6.3 KB | 20.3 KB |
| `brainfold` | 1.0 KB, ~240 tokens | 0.5 KB | 10.2 KB |

A query that names a bullet's handle outright returns that bullet and its
near ties, not eight neighbours, and `--budget <tokens>` caps any answer.

Measured on real sessions instead, with `just proof`: twelve questions each
answerable from one bullet, asked of Claude Code with no notes, with the
vault as plain markdown it must search itself, and through `brain`. Two
repeats, 2026-09-29; tokens are everything the run processed.

| model | condition | correct | tokens per question | turns |
|-------|-----------|--------:|--------------------:|------:|
| sonnet | no notes | 38% | 33,650 | 1.0 |
| sonnet | plain markdown | 92% | 196,037 | 6.0 |
| sonnet | `brain` | 92% | 72,411 | 2.2 |
| opus | no notes | 46% | 25,322 | 1.1 |
| opus | plain markdown | 100% | 113,870 | 5.4 |
| opus | `brain` | 92% | 48,920 | 2.7 |
| fable | no notes | 42% | 28,139 | 1.2 |
| fable | plain markdown | 100% | 104,024 | 5.2 |
| fable | `brain` | 88% | 51,641 | 2.8 |

Notes make the agent right; `brain` makes that cost a third to a half of
searching the files by hand. Haiku answered from training without looking
in most runs under both notes conditions (54% and 62% correct), which is
what the session hook is for: it pushes the repository's briefing into
context instead of waiting for a lookup.
Reading the three core files instead costs 60.3 KB, about 15,000 tokens,
per lookup. The whole vault is about 176,000 tokens. `brain recall` keeps
the same shape: five snippets for `hyprctl eval` came to 0.9 KB.

## Use

```
brain find <terms...>     search the vault; --budget <tokens> caps the answer
brain pack [<project>]    the briefing to open a project with, cached until the vault changes;
                          installed as a Claude Code SessionStart hook
brain propose '<bullet>'  queue a fact for a person to approve; brain inbox lists and moves them
brain export <agent>...   write this repository's pack into the agent's own file: CLAUDE.md,
                          AGENTS.md (Codex, OpenCode, Jules, Junie, Zed, Warp), Copilot, Gemini, Cursor, Cline, Kiro
brain import claude       propose what Claude Code remembered on its own; or any markdown list
brain mcp                 the same over MCP on stdio, for agents without a shell
brain recall <terms...>   search past agent conversations
brain locate              print the vault's path
brain doctor              what is stale, thin, duplicated or orphaned
brain log                 what keeps missing, and who asks
brain ledger              what lookups cost and saved, by caller, session and day
brain lint                check bullet form
brain secrets             scan for credentials
brain reindex             rebuild the index (automatic; rarely needed)
brain update              fetch the latest release
```

Every command above answers `--json` with one object, so a script or an app
reads the same thing a person does.

Recall is opt in, once per agent: `brain recall --enable claude`.

## Give it to your agents

Add three lines to whatever file your agents read at startup:

> The Brain is this machine's shared memory. `brain locate` prints its path,
> `brain find <handle>` searches it, and `brain recall <terms>` searches what
> was said in past conversations.

Bullets in the vault look like this, one fact each:

```
- **handle** (aliases) — the fact — source — 2026-09-28
```

## Build from source

Needs [Odin](https://odin-lang.org) and `just`.

```sh
git clone https://mordaunt.dev/code/brainfold && cd brainfold
just install ~/Documents/Brain
```

## Learn more

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the index, recall, hooks and
updates work, and what each file in this repository is for.
