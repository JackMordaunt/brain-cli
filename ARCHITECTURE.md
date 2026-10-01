# Architecture

How `brain` works, for people changing it. The [README](README.md) is
enough to use it.

## Two repositories

This repository is the tool. The notes are a separate repository: private,
committed on your own schedule, never mixed with the CLI's history.

`brain install [path]` records the vault in `~/.config/brain/vault`, puts
`brain` on PATH, points the vault's git hooks at this checkout, and builds
the index. The vault is the path given, else `BRAIN_VAULT`, else the one
already recorded, else `~/Documents/Brain`, created as a new git repository
with a starter `AI/` when it does not exist. Nothing is searched for. Run
`brain install <path>` again to move to another vault.

A single checkout holding both still works: if the checkout has an `AI/` in
it, that is the vault too.

## Installers and releases

`install.sh` and `install.ps1` fetch the released binary for the machine
they run on, check its sha256 against the release's `sha256sums.txt`, and
put it in `~/.local/bin`. Both end by running `brain install`, so a machine
with no vault gets one. `BRAIN_VERSION` pins a release tag and
`BRAIN_BINDIR` picks the directory. Releases are built by
`.github/workflows/release.yml` on a calendar tag, the way Odin tags its
own: `dev-YYYY-MM`, a letter for a second release in a month
(`dev-2026-09a`), and `dev-YYYY-MM-rcN` for a release candidate, which is
published as a prerelease and so is never what `latest` or `brain update`
offers. The installers run before any
binary exists, so they repeat the release base URL the binary owns;
`just test-installer` checks that all three agree.

On Windows, `brain install` links the binary into `~/.local/bin` (Developer
Mode) or copies it; add that directory to the user PATH for PowerShell and
cmd. Git Bash users get it from `.bashrc`. Re-run install after a rebuild
when the binary was copied.

## Updates

A release binary keeps itself current. `brain update` fetches the latest
release, verifies the Ed25519 signature on its checksum file with the key
compiled into the binary, checks the download against that file, keeps the
old binary as `brain.old`, swaps the new one in and runs it. At a terminal,
`brain` checks for a release once a day, with a 3 s timeout, and after
the command's output says on stderr that one is waiting, on every run
until `brain update`; the finding is kept in the state directory. It never
downloads on its own, a failed check waits a day like any other, and hooks,
agents and pipes never see the notice. `BRAIN_NO_UPDATE=1` silences it.
`brain version` prints the build's
tag, or `dev` for a local build, which never updates itself, and the commit
it was built from, with `-dirty` when the tree had uncommitted changes; the
justfile and the release workflow pass it as `-define:COMMIT`.

## The vault's shape

Three core files, `AI/MEMORY.md`, `AI/LEARNINGS.md` and `AI/TUNINGS.md`,
hold bullets of one fact each:

```
- **handle** (aliases: what a future searcher might type) — the fact — source — YYYY-MM-DD
```

`brain lint` enforces the trailing date and refuses a bullet carrying a
literal credential. Since every bullet reaches an agent's context, lint and
`brain propose` also refuse text that could steer one, with no model
involved: always, invisible and direction-changing characters, control
characters, fullwidth and mathematical letters, words mixing lookalike
alphabets, and embedded images, on every line the index reads, the
vocabulary included; and in a vault whose `.brain/policy` says `lint strict`
(or with `--strict`), bullets carrying URLs, addresses, paths, markup,
encoded runs, words addressing the reader, or wording that reads as an
instruction, and vocabulary rows longer than four plain words. A staged
check holds to the committed policy as well, so loosening it takes its own
commit. Everything else in the vault is prose, indexed line by
line, so handoffs and longer notes are findable too.

The vault's vocabulary is `AI/synonyms.tsv`: tab-separated `term` and
`expansion` rows under a header, one expansion per row. `find` widens each
query term with its rows, so `systemd` can also match a bullet that says
`user unit`. The file is reloaded whole on every `sync`. A vault without the
file has no expansion.

## The index

Markdown is canonical. The SQLite index (FTS5, linked in) is disposable:
delete it at any time and `brain reindex` rebuilds it (`sync` still works as
its old name, because installed hooks say it). Nothing the CLI stores
is authoritative, so the vault stays readable, diffable and yours.

`find` ranks handle matches above body matches, and equal scores fall to
the newer bullet. A term of three or more characters also matches as a
prefix of a handle or alias, so `libgit` reaches `libgit2`; prose keeps
exact terms. A query that is a bullet's handle or alias outright returns
that bullet first with only its near ties (`EXACT_RATIO`), not the full
`FIND_LIMIT`. An agent, recognised by its caller, gets one line per hit:
locator, handle, fact, date; `--raw` restores the line as written and
`--terse` asks a terminal for the short form. `--budget <tokens>` replaces
the default byte cap for one call. Every `find` is logged with its entry
count, its caller and the bytes it printed, which is the per-session cost a
ledger reads back. Claude Code is recognised from its own
environment; any other agent sets `BRAIN_CALLER` and `BRAIN_SESSION` so
`brain log` can say who asks and how often. A zero-hit query is a backlog
item only while it still misses: `brain log` re-runs each one and sets
aside those a later edit answered. `brain doctor` uses the same log to name
bullets returned often enough that a gate or a project file should carry
them. Doctor also lists older notes that name what a newer bullet names,
by file, heaviest first: a plan or handoff written before the bullet
settled the matter, which an agent may quote over the bullet (on the
proof, a plan's line about an install alias that was never built beat the
bullet saying so on every capable model). A note is matched by a bullet's
handle or alias as a phrase of two or more words and ten or more
characters, and a line that cites the bullet by name is not counted. Files
carry the date in their name, the vault's convention for handoffs, plans
and reports, and the index records it. The misses `brain log` lists are the backlog for editing
`synonyms.tsv`.

## The proof

`tools/proof/run.sh` measures what a lookup costs a real agent. It asks
the questions in `questions.tsv`, each answerable from a bullet in the
vault, of `claude -p` under three conditions: no notes, the vault as plain
markdown the agent must search itself, and the vault behind `brain`. Every
run is one session in an isolated home holding only credentials, so no
global instruction reaches it; the working directory's CLAUDE.md is the
whole difference between conditions. `record.py` scores each run against
the question's regex on the full answer and keeps its usage; `summarize.py`
reports per model and condition, with "beyond the prompt" as the tokens a
run added past the fixed system prompt, which every condition sends again
on every turn. `regrade.sh` re-scores a finished run from its raw files, so
a change to the grading never needs the agents run again. MODELS, REPEATS
and CONDITIONS widen a run; results land under `build/proof/<stamp>/`.

## Facts that prove themselves

A bullet is stale by its date alone until something checks it. `brain
verify` reads each core bullet's fact for the claims a machine can test:
a path under a root machines have (`PATH_ROOTS`; a lone `/flag` or a
URL's path is not one), a file in the vault named with or without its
`AI/` prefix, a `brain <subcommand>` against `COMMANDS`, and a commit of
seven or more hex characters, looked for in the repositories the same
bullet names, else in every repository the transcripts saw an agent work
in. The verdicts land in a `claims` table in the index, carried across
reindexes until the next run, and the failures print one per line.
`--apply` rewrites the date on every bullet whose claims all passed, a
markdown edit the person commits, so the date means checked rather than
old. On the working vault the first run named a checkout that had moved
and commits no local repository held.

Doctor gained three reads on top of its sections: the claims that failed
the last verify; `suspect`, a bullet served at rank three or better
within ten turns before the person corrected the agent in that session,
which joins the find log to the transcripts on the session id; and
`contradictions`, two core bullets that answer to one handle or alias
and share no content word of four or more letters.

## Reinforcement

The find log says what was served; `brain learn` says whether it helped.
A serve was used when the session ran no later lookup on the bullet's
names, no correction followed within ten turns, and, the strong form, an
assistant turn went on to name the handle. The verdicts go to a
`serve_outcome` table. A query word of four or more letters that led to
a used bullet and is not among its names becomes an alias candidate once
three distinct sessions agree; `--apply` writes it into the bullet's
alias list. Aliases and synonym terms no query contained in 180 days are
listed as dead, synonyms pruned on `--apply`, once fifty queries are
logged. Every weight stays text a person can read and reverse.

Ranking by use is an experiment, off by default: with
`BRAIN_RANK=weighted`, find subtracts `min(1.0, 0.5 ln(1 + used))` from
a bullet's bm25, never for serves alone and never for a bullet that
failed verify, since a bullet served because it ranks high would
otherwise rank higher for being served. `--plain` turns it off for one
call and the proof's `brain-weighted` condition, which starts from this
machine's own log, decides whether it ships.

## One voice, one JSON face

Output speaks in outcomes: what the vault knows, what is waiting, what a
lookup cost. Git and SQLite are named where a curious reader looks, in
`--help` and here, not in the default output. Every command that reports
state answers `--json` with one object on stdout, keys in a fixed order, so
the desk and any script read the same thing a person does without scraping
tables; `brain/json.odin` is the writer and `jw_rows` turns a query into an
array of objects keyed by column name, which is how doctor, log and ledger
get theirs. Under `--json` an error is `{"error": ...}` on stdout with a
non-zero exit. install, uninstall, update and mcp do not speak JSON.

`brain ledger` reads the find log back as cost: tokens returned per caller,
session and day, and tokens saved against the alternative an agent has
without an index, reading the three core files whole. Tokens are bytes over
four, the README's estimate.

## Packs

`brain pack [<project>]` is the briefing an agent opens a project with: the
bullets that name or mention it, terse, within `--budget` tokens (1500 by
default), then one line naming the project's newest handoff and one
counting the files in its state folder. With no project named it takes the
repository the caller is in, the nearest `.git` above the working
directory, so a session hook needs no argument. It exists so a session hook can
put what the vault knows about a repository at the start of context, where
a host's prompt cache can hold it, instead of the agent rediscovering it
three lookups at a time. The pack is cached under the state directory
against the index's build stamp (`meta.built`, written on every sync), so
serving it costs nothing until the vault changes; `--fresh` rebuilds it.
Each serve is logged as a query with its bytes.

`brain install` registers `brain pack` as a Claude Code SessionStart hook
in `~/.claude/settings.json`, for a session's start, `/clear` and
compaction, beside whatever hooks are there, and two more hooks with it
(see "Memory that happens" below). A miss prints nothing, so a
repository the vault knows nothing about costs no error. Each hook is
recognised by its command: a second install adds nothing, `brain
uninstall` removes only them, and `brain hooks [on|off]` shows and
toggles the three. A settings file that does not parse is left alone and
named, since a bad write there would take every hook with it. The pack
logs the handles it served, like a find, so a prime in the same session
does not repeat them.

## Memory that happens

The agent never has to call find or propose. Three moments in a session
carry it: the start, each prompt, and the point where the agent would
stop. `brain pack`, `brain prime` and `brain settle` answer those moments
and know no harness: prime takes the prompt and a session id as flags,
settle a session id and the transcript's path. A harness adapter in
`brain/hooks.odin`'s `HARNESSES` table is the thin layer per program:
whether the program is on this machine, how to register the three
commands with it, how to read the input it hands over, and how to word
the reply that continues a turn. `brain hooks [on|off] [--harness
<name>]` drives every harness here, and install and uninstall go through
the same table.

- **Claude Code** (`brain/harness_claude.odin`) registers three command
  hooks in `~/.claude/settings.json`. Its hooks hand JSON over on stdin
  (`prompt`, `session_id`, `transcript_path`, `stop_hook_active`), which
  `claude_parse` reads, and a Stop hook continues with
  `{"decision":"block","reason":...}`.
- **pi** (`brain/harness_pi.odin`) is registered by writing one
  TypeScript extension, `~/.pi/agent/extensions/brain.ts`, with the
  binary's path inside it and a first line it is recognised by. The
  extension runs pack at `session_start`, prime at `before_agent_start`
  with the prompt after `--`, and settle at `agent_before_settle` with
  the session file; each result goes to the model as a custom message
  the transcript keeps and does not display, and settle's reason comes
  back as `{"reason":...}`, which the extension appends with
  `continue: true`. pi hands nothing over on stdin.

Adding a harness is one file: a detect, a register and unregister, a
status, a parse when the program speaks on stdin, and a reply.

Prime takes the prompt's words less the ones that carry nothing
(`PRIME_STOP`) and any pasted block, and finds what the vault holds
about them. A bullet
holding every term answers; when none does, the bullets holding enough
of the terms do, a third of them and at least two, most covered first,
so one shared word like git brings nothing. Note lines follow the same
way, a quarter of the terms and at least two, since a line is one
wrapped line of a paragraph. Everything printed is logged as served to
the session, bullets by handle and lines by locator, and is not served
again in that session, by prime, pack or find. A prompt that found
nothing is told once a session that brain is there to ask, since no
instruction may name it. The default budget is 600 tokens a prompt.

`brain settle` runs where the agent would stop. It exits silently unless
all of: the stop is not already a continuation, the session has six or
more assistant turns, it changed something (an edit, a write or a shell
call, by tool names compared in lower case since harnesses spell them
differently), and no `brain propose` ran. The transcript is read through
the harness's recall adapter with the title requirement off (`scan`), so
a session still running counts. Then, once per session (a stamp under
the state directory), it replies in the harness's own words: the ask to
propose each durable fact the session settled or reply none, with the
session's corrections (see "Lessons") quoted so the agent writes the
lesson while it still knows why. The model already holding the context
does the extraction; no second model is called.

The proof has a `brain-auto` condition for this: a home whose only
difference from vanilla is the three hooks, and a CLAUDE.md that names
nothing. On sonnet, 2026-10-01, it answered every bullet question at
half the tokens of the `brain` condition in one turn, and lost the
questions whose answer lives only in a note until prime served note
lines too.

## Proposals

Nothing an agent writes enters memory unseen, but a person chooses whether
they see it before or after agents do. `brain propose '<bullet>'` completes
the line (the caller as source, today as date when they are missing),
checks it parses as a bullet, and appends it to `AI/INBOX.md`. `brain
inbox` numbers the proposals; `approve <n> [--to LEARNINGS]` appends the
line to a core file, removes it from the inbox and resyncs; `drop <n>`
moves it to `AI/DROPPED.md`, which the scanner never reads and `propose`
checks, so an agent cannot propose the same handle and fact again.

`brain review` sets when that happens, per machine, in
`~/.config/brain/review`; `BRAIN_REVIEW` overrides it. Review after, the
default, indexes the inbox with the core files: a proposal answers a
`find` at once, its locator followed by `(unreviewed)` and `"reviewed":
false` under `--json`, and loses a tie with a reviewed bullet. A person
drops what is wrong when they get to it. Review before skips the inbox, so
a proposal answers nothing until approved. The index records which setting
built it and rebuilds when it changes. A queue nobody clears is why after
is the default: under before, an unread inbox means agents never see what
they learned. Either way the inbox is markdown in the vault like everything
else, so it is diffable, and the review is the commit.

## Export and import

Every coding agent reads a markdown file at the root of a repository
before it starts, each under its own name, and each keeps what it learns
in a place the others cannot read. `brain export <agent>...` writes the
repository's pack into that agent's file, so the vault is the durable
store and the file a view of it: run it again after the vault changes and
every agent opens with the same facts. Shared files get a managed block
beside whatever is there: `CLAUDE.md`, `AGENTS.md` (Codex, OpenCode,
Jules, Junie, Zed and Warp read it), `.github/copilot-instructions.md`,
`GEMINI.md`. Files brain owns are written whole with the frontmatter that
agent expects: `.cursor/rules/brain.mdc` (`alwaysApply: true`),
`.clinerules/brain.md`, `.kiro/steering/brain.md` (`inclusion: always`).
The block enters the repository like any other file, so export is a
deliberate command, never a hook. The set is the agents in the top ten by
use in 2026 or backed by Google, Amazon or Microsoft, with the trailing
ones left out; the table is `TARGETS` in `brain/export.odin`.

`brain import claude` reads what Claude Code remembered on its own, one
file per memory under `~/.claude/projects/<slug>/memory/` with `MEMORY.md`
as the index, and proposes each as a bullet with the memory's body as the
fact and its type as the source. `brain import <file.md>` reads any other
markdown list the same way, the first words of a line as its handle. Both
go through the inbox: nothing enters the vault until a person approves it.
Copilot Memory and Cursor Memories are server-side and cannot be read.

## MCP

`brain mcp` speaks the Model Context Protocol on stdio, for agents that
have no shell: `find`, `recall`, `pack`, `propose` and `locate` as tools.
Each call runs the command the CLI would in a Cli of its own and returns
what it printed, so the tools cannot drift from the commands; the caller
is logged as `mcp:<client>` from the client's own name. Register it with
`claude mcp add --scope user brain -- brain mcp`, or the equivalent in
another client.

## Recall

`brain find` answers what was concluded and is still true. `brain recall`
answers what was actually said, across your agents' transcripts:

```
brain recall --enable claude      # opt in, once, per agent
brain recall <terms...>           # ranked snippets
brain recall --full <id>          # one turn in full
brain recall --sync               # full re-ingest; normally automatic
brain recall --sources            # which adapters exist and which are on
```

Transcripts are not vault content. They are machine-written, never
committed, and their formats belong to other people's programs, so they
live in their own database (`transcripts.db`), behind their own command,
and nothing about them reaches the markdown.

A turn is identified by the agent's own id, so a session resumed into a new
file re-inserts nothing. Results are snippets, not whole turns: ten hits
cost about half a kilobyte rather than the ~20 KB the full bodies would.

A recall hit is evidence of what was said, not of what is true. A claim
retracted three turns later reads exactly like a sound one. Vault bullets
and the current code outrank it.

The current session is excluded by default, so an agent asking whether it
has discussed something does not find itself. A conversation resumed into a
second file can still surface its earlier half; `--all` turns the filter
off.

### Tool calls

Beside the turns, the recall database keeps a `tool` table: every call
the agent made, with the one input worth searching (a shell command, a
path, a pattern) and whether its result was an error, read from the
transcript's `tool_use` blocks and the `tool_result` blocks that answer
them by id. A database written before the table existed fills it with
one full pass. Three commands read it:

- `brain howto <terms>` finds the session whose shell commands or title
  match best and replays the chain around the best successful call: the
  shell commands between the prompt before it and the prompt after,
  failures dropped, a command repeated back to back kept once. `--all`
  lists the sessions; `--propose` writes the chain into the repository's
  state folder in the vault (`<repo>/howto-<slug>.md`) with a bullet
  pointing at it, sourced `recall:<session>`.
- `brain lessons` lists the moments nothing read back: a short user turn
  that opens with a correction marker (`LESSON_STARTS`, matched as whole
  words, with `LESSON_NOT_STARTS` for "no problem") or holds one
  (`LESSON_PHRASES`) after something the agent said; and a shell command
  that failed and then, within three calls, worked once retouched (same
  program, an edit in three characters covers the difference). No model
  is involved. `--propose` queues each as an inbox bullet whose source
  is the turn id, so `brain recall --full <id>` shows why. Settle quotes
  the session's corrections, and doctor's suspect section joins them to
  the find log.
- `brain day [YYYY-MM-DD]` and `brain week [--since Nd]` are the
  timeline: sessions by local day and the directory they ran in, each
  with its title, its first prompt as the goal, its span and turn count,
  then the repository's commits in the window from `git log` when the
  directory is on this machine.

### Adding an agent

One `Adapter` in `brain/adapters.odin`: a `list` proc that names every
transcript on the machine and an `emit` proc that turns one transcript into
a `Transcript`: `Turn` values (id, timestamp, role, session, title, cwd,
body) and `Tool` values (id, the turn's id, timestamp, name, input, ok).
Add it to `ADAPTERS` and `brain recall --enable <name>` knows it. The
fixture adapter reads a sibling `<name>.tools.tsv` for its calls.

A transcript with no title is a headless API run, not a conversation, and
should emit nothing. That is the difference between every file on disk and
the few worth recalling.

## Hooks

The hooks and the gitleaks ruleset are compiled into the binary. `brain
install` writes the hooks under `~/.config/brain/hooks` with the binary's
own path inside them, so a release binary needs no checkout and a hook runs
whatever PATH git was started with. Edit the files here; a rebuild picks
them up.

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
| `branding/` | the mark and hero lockup, light and dark, SVG and PNG; `just branding` regenerates them |
| `tools/logo/` | the logo lab: the mark's geometry, its SVG writer, and the grid of variations it was chosen from (`just logo`) |
| `tools/proof/` | the proof: the same questions asked of real Claude Code sessions with no notes, with the vault as plain markdown, through brain, and with the hooks alone (`brain-auto`); `just proof`, then `regrade.sh` to re-score a run without re-running it |
| `tools/desk/` | the desk prototype: the control room over a vault on jm:ui/material, against fixture data (`just desk`) |
| `tools/host/` | the window both tools run in; `just hot DIR TITLE` rebuilds a child on save and the host respawns it |
| `jm/` | the [jm collection](https://mordaunt.dev/code/jm), pinned as a submodule |

`testdata/vault` is a fixture of exactly the vault's shape; `just test` runs
the whole suite against a copy of it, so the tests pass on a machine with
no notes at all.

## Requirements

To run: one static binary. SQLite with FTS5 is linked in; nothing is needed
on PATH. `git` is used by `brain lint --staged`, `brain secrets`, and the
hooks. `gitleaks` is optional and improves `brain secrets`.

To build: [Odin](https://odin-lang.org) and the jm collection. `just build`
fetches the submodule and builds its SQLite archive when either is missing;
`JM=<path>` builds against another checkout instead.

## Development

```
just build     debug binary with the debug allocator and ASan -> build/debug
just release   optimised binary                                -> build/release
just test      the package's tests against the fixture vault
just check     type-check for linux, darwin and windows
just install   bind this machine to a vault
just logo      open the logo lab
just desk      open the desk prototype
just branding  regenerate branding/
just preview   render the docs to build/ and open them
```
