# Proof suite: what brain does for an agent, measured

The 2026-09-29 proof measured one thing: what a single-fact lookup costs.
This suite scores the whole claim, "memory makes the agent right, cheaply,
and keeps getting better", on named axes, each with an experiment whose
result can go up or down. Every experiment runs the same three controls,
so a number means something only against its neighbours:

| control | what the agent has | stands for |
|---|---|---|
| `vanilla` | an empty scratch directory, no notes | an agent with no memory |
| `plain` | the vault as markdown, told the bullet shape and to search it (grep, Read) | memory as files, no tool |
| `brain` | the vault behind the `brain` CLI, told to ask it | the product, instructed |
| `brain-auto` | no instruction names brain; the hooks pack, prime and settle | the product as installed, pushed not pulled |

Every run is one `claude -p` session in an isolated home holding only
credentials; the working directory's CLAUDE.md is the whole difference
between conditions. Model under test: `sonnet` by default (MODELS= widens).

## Axes

| axis | question it answers | metric | experiment |
|---|---|---|---|
| A1 Recall | does the agent get a known fact right? | correct / runs (regex per question) | `lookup`, `paraphrase`, `multihop`, `scale-*` |
| A2 Cost | what does being right cost? | tokens, turns, dollars, seconds per run | every experiment |
| A3 Calibration | when the vault has nothing, does it say so or make something up? | abstain rate; trap rate (a fabricated specific) | `absent` |
| A4 Uptake | does a known pitfall change what the agent *does*, unasked? | task check passes (regex or runnable check over files written) | `tasks` (covered rows) |
| A5 Overhead | what does memory cost on work it cannot help? | tokens and correctness delta vs vanilla | `tasks` (uncovered rows) |
| A6 Capture | does a fact learned in a session get written down, well? | captured; passes `brain lint`; not a duplicate | `capture` phase 1 |
| A7 Round trip | can the next session use what this one learned? | correct in a fresh session | `capture` phase 2 |
| A8 Robustness | does a stale note, a reworded ask or a big vault break it? | correct; trap rate; tokens vs vault size | `conflict`, `conflict-marked`, `paraphrase`, `scale-300`, `scale-3000` |

A9 Transcript recall (`brain recall`: what was said, not what was concluded)
is designed but not run: it needs questions written against this machine's
own transcripts and a `plain` control that greps `~/.claude/projects`. See
"Not yet" below.

## Experiments

- **lookup** (A1, A2). `questions.tsv`, the 2026-09-29 set: 12 bullet
  questions, 4 note-only. Conditions: vanilla, plain, brain, brain-auto.
- **paraphrase** (A1, A8). `questions-paraphrase.tsv`: the same 12 facts
  asked in words that share as little as possible with the bullet's handle
  and aliases. Tests the synonym table, prefix matching and the agent's own
  query choice. Conditions: plain, brain. Score against `lookup`.
- **multihop** (A1). `questions-multihop.tsv`: answers that need two bullets.
  Expected regex requires both parts. Conditions: vanilla, plain, brain.
- **absent** (A3). `questions-absent.tsv`: questions in the vault's domain
  whose answer is not in it. `expected` is an abstain pattern; `trap` is the
  shape of a made-up specific (a port number, a version). Correct means
  abstained and did not fall in the trap. A haiku judge reads each answer too
  (`judge.py`), recorded beside the regex. Conditions: vanilla, plain, brain.
- **conflict**, **conflict-marked**, **conflict-tended** (A8).
  `vaults.py conflict` plants a 2026-09-20 note that contradicts five
  bullets with a plausible stale specific. `-marked` adds a generic
  superseded header; `-tended` is the planted vault after `brain tend` and
  a person approving its supersede items (the header names the bullets).
  Questions are the five lookups, `trap` is the stale specific. The regex
  trap counts a mention; `judge.py --mode conflict` (haiku) says which value
  the answer asserts, CURRENT, STALE or BOTH, and is the headline, because
  an answer that gives the current fact and calls the old one deprecated
  trips the regex. Conditions: plain, brain. The 2026-09-29 proof found the
  best models prefer a concrete wrong line in a note to a bullet.
- **scale-300**, **scale-3000** (A2, A8). `vaults.py scale N` appends N
  synthetic bullets, deterministic from a seed, 5 percent of which reuse the
  real questions' key words with other facts. Six lookup questions.
  Conditions: plain, brain. The claim: plain's tokens grow with the vault,
  brain's do not, and neither loses accuracy.
- **tasks** (A4, A5). `tasks.tsv`: eight tasks where a bullet changes the
  right action (covered) and four it cannot help (uncovered). Prompts never
  mention notes. A `repo` column names the repository a task happens in;
  the working directory takes that name and a `.git`, so `brain pack`
  serves that project's bullets as it would in the real repository
  (`--no-repo` runs every task in a scratch directory, as the runs before
  2026-10-02 14:48Z did). The check reads the answer and every file the agent wrote;
  `py:` checks are executable (the Hyprland rule's regex must full-match the
  real class string; a script must run and print the right thing).
  Conditions: vanilla, plain, brain, brain-auto.
- **capture** (A6, A7). `capture.tsv`: the prompt states a fact the vault
  does not hold and asks for a small task that writes files. Phase 1
  measures capture: a bullet appeared (`AI/INBOX.md` via propose, or any
  vault file in plain, or any file in the scratch directory for vanilla) and
  passes `brain lint`. Phase 2 opens a fresh session on the same vault and
  directory and asks the question. Conditions: vanilla, plain, brain,
  brain-auto (settle runs on Stop once a session changed files and proposed
  nothing).

- **tend** (A8, hygiene). Not an experiment of its own: `brain tend`
  on a copy of the vault, then `brain inbox approve` for its supersede
  items, produces the `conflict-tended` vault. The number to watch is how
  many items a sweep proposes on the real vault (the first content-only
  sweep proposed 11: 5 supersede, 1 drop, 5 merge) and whether the planted
  note is among them.

## Reading the scorecard

`scorecard.py <suite dir>` prints one table per axis. The headline numbers:

- A1: brain within 1 of plain on bullet questions, both far above vanilla.
- A2: plain / brain token ratio; the 2026-09-29 figure was 2.0 to 2.7.
- A3: brain and plain should abstain more than vanilla, and never trap more.
  If brain traps more than plain, find's output is being read as an answer.
- A4: brain-auto is the number that matters: it is how brain ships. If
  brain-auto is near vanilla, prime is not reaching the model or the model
  is not acting on it.
- A5: brain-auto minus vanilla tokens on uncovered tasks is the tax of the
  pack and prime; it should be a few thousand tokens and no accuracy loss.
- A6/A7: capture rate then round-trip rate per condition. Plain can write
  the file; the question is whether it does, and whether what it wrote
  passes lint.
- A8: conflict trap rate, with and without the marker; paraphrase minus
  lookup; tokens at 300 vs 3000 bullets.

## Running

    just release
    tools/proof/suite.sh                  # smoke: a subset of each experiment, sonnet, once
    SMOKE=0 tools/proof/suite.sh          # the full suite
    MODELS="sonnet opus" REPEATS=2 SMOKE=0 tools/proof/suite.sh
    EXPERIMENTS="tasks capture" tools/proof/suite.sh
    python3 tools/proof/scorecard.py build/proof/suite-<stamp>
    python3 tools/proof/compare.py build/proof/suite-<before> build/proof/suite-<after>
    CONDS="brain brain-auto" EXPERIMENTS="tasks capture" tools/proof/suite.sh   # an after-run on one change

Each experiment writes `build/proof/suite-<stamp>/<experiment>/` with
`raw/*.json`, `runs.jsonl` and `summary.md`; the suite writes
`scorecard.md` at the top. `regrade.sh` rebuilds any lookup-style
experiment's grades without rerunning the agents.

## Harness notes

- Every run's record lists its tool calls (`tools`, `brain_calls`,
  `file_reads`, `denials`), so a number can be explained: a brain-auto run
  that is right with zero calls was primed; a brain run with zero calls did
  not ask.
- `plain` gets the vault as an added working directory (`--add-dir`), since
  Claude Code's Read and Grep refuse paths outside one; before that, one
  plain session in the first smoke answered from training and said so.
- Outside a git repository `brain pack` prints nothing, so in a scratch
  directory brain-auto is prime alone; tasks with a `repo` column add the
  pack. The lookup runner has `brain-auto-b300` and `brain-auto-b1200`,
  the hooks-only condition with prime's budget turned (BRAIN_PRIME_BUDGET)
  against the 600-token default.
- Sessions in the behaviour runner persist (in the run's own home): the Stop
  hook reads the transcript from disk, so under `--no-session-persistence`
  settle can never fire. The lookup runner still disables persistence, so
  settle is measured only by `behave.py`, which records `settle_asked`.
- Hooks are registered with the bare name `brain` (BRAIN_EXE=brain): an
  agent that sees a hook command copies its spelling, and the harness's
  `Bash(brain:*)` allow rule matches only the bare name.
- Vault copies leave out `AI/INBOX.md`, any file named `proof`, and any
  bullet whose text mentions the proof: the inbox holds proposals the
  proof's own sessions made, the write-ups name the questions and their
  answers (a session once recognised itself as a test case from one), and
  proposals about the proof that a person approved into the core files say
  which query misses which bullet.
- The behaviour runner keeps what each run wrote under `files/<run>/`, and
  the capture runs add `GAINED.md`, the vault lines the session added.
- Results so far (2026-10-02, sonnet): the smoke (100 runs, $9) and the
  after-run of four product changes (48 runs, $5) are written up in the
  Brain, `brainfold/2026-10-02-proof-suite-results.md`.

## Not yet

- A9 transcript recall: seed `BRAIN_STATE` with this machine's
  transcripts.db, give plain the `~/.claude/projects` jsonl path, write
  questions whose answer was said in a session and never made a bullet.
- Cost of being wrong: a wrong answer's cost is the work that follows it.
  The tasks experiment is the first step; a multi-turn version where the
  agent must run its own output would measure it.
- Judge for free-form tasks: `judge.py` exists; tasks use executable checks
  where they can so the judge stays optional.
