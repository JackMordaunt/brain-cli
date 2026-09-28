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
curl -fsSL https://mordaunt.dev/code/brain-cli/install.sh | sh
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-macos-dark.svg">
  <img src="branding/badge-macos-light.svg" alt="macOS" height="36">
</picture>

```sh
curl -fsSL https://mordaunt.dev/code/brain-cli/install.sh | sh
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-windows-dark.svg">
  <img src="branding/badge-windows-light.svg" alt="Windows" height="36">
</picture>

```powershell
irm https://mordaunt.dev/code/brain-cli/install.ps1 | iex
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
- **A cache, not a database.** The SQLite index is disposable. Delete it, `brain sync` rebuilds it from the markdown.
- **One binary that keeps itself current.** `brain update` fetches a signed release. It never updates unasked.

## What a search costs

Measured on a working vault of 88 files, 504 KB. The grep columns search
for the query's first word, the way an agent without an index would start.
Tokens are bytes over four.

| query | `brain find` | `grep -ri` over `AI/*.md` | `grep -ri` over the vault |
|-------|-------------:|--------------------------:|--------------------------:|
| `hyprland window rule` | 1.8 KB, ~460 tokens | 4.1 KB | 7.3 KB |
| `jm hot-watch` | 0.7 KB, ~180 tokens | 19.0 KB | 43.4 KB |
| `sqlite fts5` | 1.6 KB, ~400 tokens | 5.9 KB | 16.6 KB |
| `brain-cli` | 4.4 KB, ~1,100 tokens | 8.9 KB | 11.4 KB |

Reading the three core files instead costs 57.6 KB, about 14,000 tokens,
per lookup. The whole vault is about 126,000 tokens. `brain recall` keeps
the same shape: five snippets for `hyprctl eval` came to 0.9 KB.

## Use

```
brain find <terms...>     search the vault
brain recall <terms...>   search past agent conversations
brain locate              print the vault's path
brain sync                rebuild the index
brain doctor              what is stale, thin, duplicated or orphaned
brain lint                check bullet form
brain secrets             scan for credentials
brain update              fetch the latest release
```

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
git clone https://mordaunt.dev/code/brain-cli && cd brain-cli
just install ~/Documents/Brain
```

## Learn more

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the index, recall, hooks and
updates work, and what each file in this repository is for.
