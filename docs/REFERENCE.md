# brainfold reference

Everything the README leaves out: install options, every command, how output
is shaped for agents and people, and how to build from source. For how the
pieces work inside, read [ARCHITECTURE.md](../ARCHITECTURE.md); for what it
costs and saves, measured, read [PROOF.md](PROOF.md).

## Install

```sh
curl -fsSL https://mordaunt.dev/code/brainfold/install.sh | sh      # Linux, macOS
irm https://mordaunt.dev/code/brainfold/install.ps1 | iex           # Windows
```

Each installer downloads the release for your machine, checks its hash, puts
`brain` in `~/.local/bin`, and creates a vault at `~/Documents/Brain` if you
do not have one yet. Already keep notes somewhere? Point at them instead:

```sh
BRAIN_VAULT=~/notes sh install.sh     # at install time
brain install ~/notes                 # any time after
```

`brain install` also writes the three hooks into Claude Code and pi, and a
short block into `~/.claude/CLAUDE.md` saying what the Brain is. `brain
uninstall` removes both; the vault is untouched.

## The vault

An ordinary directory of markdown. Obsidian opens it, `grep` works on it, and
it versions like any folder of text. Facts live one per line in `AI/MEMORY.md`,
`AI/LEARNINGS.md` and `AI/TUNINGS.md`:

```
- **handle** (aliases: what a searcher might type) — the fact — source — 2026-09-28
```

Longer notes, plans and handoffs live in any other folder and are searched
line by line. `AI/synonyms.tsv` is the vocabulary: `systemd` also finds the
bullet that says `user unit`. `AI/INBOX.md` holds what agents proposed and no
person has reviewed; `AI/DROPPED.md` what a person rejected; `AI/TENDED.md`
what `brain tend` applied.

## Commands

```
Ask
  brain find <terms...>      what the vault knows; handles first, then note lines;
                             --budget <tokens> caps the answer
  brain pack [<project>]     the briefing a session opens with; --budget, --fresh
  brain prime [<prompt>]     what the vault knows about one prompt, once per session
  brain recall <terms...>    what past agent conversations said; --limit, --full <id>,
                             --sessions, --enable <agent>, --sources
  brain howto <terms...>     the shell commands that did it last time; --all, --propose
  brain day [YYYY-MM-DD]     what was worked on that day, by repository
  brain week [--since Nd]    the same for the last seven days; --project <name>, --no-git
Remember
  brain propose '<bullet>'   add a fact for a person to review; --force for a correction
  brain settle               the Stop hook: once per session that changed files and
                             proposed nothing, ask what it settled
  brain lessons              corrections and retries from the transcripts; --propose
  brain inbox                what is unreviewed; approve <n>|all [--to LEARNINGS], drop <n>
  brain review [after|before]  after (default): a proposal answers finds at once, marked
                             unreviewed; before: only once approved
  brain import claude        propose what Claude Code remembered on its own; or <file.md>
Share
  brain export <agent>...    write this repository's briefing into the agent's own file:
                             claude, agents (codex, opencode, jules, junie, zed, warp),
                             copilot, gemini, cursor, cline, kiro
  brain mcp                  the same tools over MCP on stdio, for agents without a shell
Keep it healthy
  brain tend                 sweep the vault: aliases now; supersede, drop, merge and date
                             as inbox items a person approves; runs daily at Stop;
                             --quick, --dry-run
  brain doctor               what is stale, thin, oversized, duplicated or orphaned, which
                             notes a newer bullet may have superseded, which claims failed
  brain learn                query words to wire as aliases, aliases nobody asks for; --apply
  brain verify [<handle>..]  test the claims bullets make: paths, vault files, subcommands,
                             commits; --apply dates what passed
  brain log                  what keeps missing, and who asks
  brain ledger [--days N]    what lookups cost and saved, by caller, session and day
  brain lint [--staged]      check bullet form; --strict refuses text that steers agents
  brain secrets [--staged]   scan for credentials; --history, every commit
  brain reindex              rebuild the index from the markdown (automatic; rarely needed)
Set up
  brain install [<vault>]    bind this machine to a vault; --dry-run shows the plan
  brain uninstall            undo those bindings
  brain locate [--tool]      the vault's path; --tool, this CLI's checkout
  brain hooks [on|off]       pack, prime and settle in every harness here; --harness <name>
  brain update               replace this binary with the latest signed release
  brain version              this build
```

Every command above the Set up line answers `--json` with one object.

## The hooks

`brain install` registers three hooks in Claude Code (`~/.claude/settings.json`)
and pi (one extension file):

- **pack** at session start: the bullets about the repository you are in.
- **prime** on every prompt: the bullets and note lines that hold enough of
  the prompt's words, each served once a session, within `BRAIN_PRIME_BUDGET`
  tokens (1200 by default).
- **settle** when the agent would stop: once per session that changed files
  and proposed nothing, a block asking it to propose what it settled, naming
  the files it wrote. The same moment runs the day's first `brain tend`.

The commands know no harness; one adapter per program registers them, and a
new harness is one file.

## Output

Text is styled only for a person at a terminal. A pipe, an agent (it sets
`AI_AGENT`, `CLAUDECODE` or `CODEX_SANDBOX`) and `NO_COLOR` get plain text, so
styling costs an agent nothing; `--color=always|never|auto` or `BRAIN_COLOR`
overrides. An agent gets one line per bullet, handle, fact and date, and a
note hit as its paragraph; a terminal gets the line as written.

Recall is opt in, once per agent: `brain recall --enable claude`.

## Environment

| variable | what it does |
|---|---|
| `BRAIN_VAULT` | the vault, instead of the one `brain install` recorded |
| `BRAIN_STATE` | where the index and hook state live (default `~/.local/state/brain`) |
| `BRAIN_PRIME_BUDGET` | tokens prime may give a prompt (1200) |
| `BRAIN_REVIEW` | `after` or `before`, when proposals are reviewed |
| `BRAIN_NO_TEND` | set to skip the daily sweep |
| `BRAIN_CALLER` | name the caller in the log; agents are detected without it |
| `BRAIN_COLOR` | `always`, `never` or `auto` |

## Build from source

Needs [Odin](https://odin-lang.org) and `just`. CI builds with the Odin commit
named by `ODIN_PIN` in `.github/workflows/release.yml`; other versions may not
link.

```sh
git clone https://mordaunt.dev/code/brainfold && cd brainfold
just install ~/Documents/Brain     # build, install, bind
just test                          # the package tests
just suite                         # the proof suite, smoke size (needs claude logged in)
```
