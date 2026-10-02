<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/hero-dark.svg">
    <img src="branding/hero-light.svg" alt="brainfold" width="560">
  </picture>
</p>

<p align="center"><b>Memory for your coding agents, in notes you own.</b><br>Plain markdown. One binary. Nothing to host. The command is <code>brain</code>.</p>

## Install

<picture><source media="(prefers-color-scheme: dark)" srcset="branding/badge-linux-dark.svg"><img src="branding/badge-linux-light.svg" alt="Linux" height="36"></picture>
<picture><source media="(prefers-color-scheme: dark)" srcset="branding/badge-macos-dark.svg"><img src="branding/badge-macos-light.svg" alt="macOS" height="36"></picture>

```sh
curl -fsSL https://mordaunt.dev/code/brainfold/install.sh | sh
```

<picture><source media="(prefers-color-scheme: dark)" srcset="branding/badge-windows-dark.svg"><img src="branding/badge-windows-light.svg" alt="Windows" height="36"></picture>

```powershell
irm https://mordaunt.dev/code/brainfold/install.ps1 | iex
```

One command puts `brain` on your machine, makes a vault if you have none, and
connects Claude Code and pi. Already keep notes? `brain install ~/notes`.

## What you get

**Your agents remember.** Every session opens knowing what the vault knows
about the project. Every prompt arrives with the facts that bear on it. The
agent never has to be told to look.

**What they learn, you keep.** When a session settles something, a decision, a
command that worked, a thing that bit, the agent is asked to write it down
before it stops. You review a line, not a transcript.

**Right at no extra cost.** Measured on real sessions: an agent with the hooks
answers from the vault as often as one that reads every file, at a fifth of
the tokens, and on plain facts at the cost of an agent with no memory at all.
[The numbers.](docs/PROOF.md)

**Still just a folder of markdown.** Obsidian opens it. Any editor edits it.
Nothing brain adds changes that, and the index rebuilds from the files any
time.

**Kept true while you sleep.** Once a day the vault is swept: facts that still
hold are confirmed, duplicates and dead facts are queued for one click of
yours, and a note that an agent might take for current says which fact
replaced it.

## How it works

Facts live one per line, with a name, the fact, where it came from and when.
A search returns the bullets that answer, best name first, sized for a
context window. Longer notes are searched too and served with the bullet
that outranks them. Three hooks carry it all into the session: the briefing
at start, the facts behind each prompt, the ask at the end.
[How, in detail.](ARCHITECTURE.md)

## Measured

| | no notes | notes as files | brainfold |
|---|---:|---:|---:|
| answers right | 31% | 97% | 97% |
| tokens per answer | 34K | 179K | 54K |
| a fact told today, known tomorrow | never | 7 of 8 | 8 of 8 |

Claude Code, 570 sessions, 2026-10-02. [Method and every axis.](docs/PROOF.md)

## For other agents

```sh
brain export codex cursor copilot    # the project's briefing, in each agent's own file
brain mcp                            # the same tools over MCP, for agents without a shell
```

## Learn more

- [Reference](docs/REFERENCE.md): every command, the hooks, output, environment, building from source.
- [Architecture](ARCHITECTURE.md): how the index, recall, hooks and updates work.
- [Proof](docs/PROOF.md): what it costs and saves, measured, and how to run the measurement.

## Licence

Apache-2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). The brainfold name
and mark are not covered; see [branding/README.md](branding/README.md).
