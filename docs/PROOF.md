# What brain does for an agent, measured

Numbers from real `claude -p` sessions, each in an isolated home where the
working directory's CLAUDE.md is the only difference between conditions.
The harness is `tools/proof` (`just suite`); its axes and method are in
[tools/proof/AXES.md](../tools/proof/AXES.md). Last full run: 2026-10-02,
sonnet, two repeats, 570 sessions.

Four conditions: **no notes**; **plain markdown**, the vault as files the
agent is told to search; **brain CLI**, told to ask `brain find`; **hooks**,
no instruction naming brain, the three hooks only.

| axis | no notes | plain markdown | brain CLI | hooks |
|---|---:|---:|---:|---:|
| recall, 16 questions from the vault | 31% | 97% at 179K tokens | 94% at 118K | 97% at 54K |
| the same, facts held in a bullet | 42% | 96% at 192K | 100% at 72K | 100% at 34K |
| tasks done the way the vault knows, 8 tasks | 25% | 88% at 328K | 100% at 199K | 100% at 172K |
| tokens added on tasks the vault cannot help | | +94K | +55K | +35K |
| a fact told to the agent, written down, recalled next session | 0/8 | 7/8 | 5/8 | 8/8 |
| answers that gave a planted stale note's value as current | | 30 to 50% | 0% | |
| absent facts: said so rather than inventing one | 100% | 80% | 94% | |

Tokens are everything the run processed: input, cache reads, cache writes,
output.

## What the numbers say

- **Notes make the agent right; the hooks make that free.** On facts held in
  a bullet, the hooked agent costs what an agent with no memory costs,
  because the prompt arrives already primed and no tool call follows.
- **Memory the agent has to ask for is memory it often does not use.**
  Told what brain is and nothing more, the agent asked in 3 of 10 task
  sessions. Told to ask before acting, 16 of 16. With the hooks, 16 of 16
  at the lowest cost.
- **Capture needs the Stop hook.** Nothing an agent is told to do at the
  end of a session happens as reliably as being asked at the end of it.
- **Files do not protect a grepping agent from a stale note**, marked
  superseded or not; ranking does. Hygiene for agents lives in what is
  served, hygiene in the files is for people.

## Reproduce

```sh
just release
tools/proof/suite.sh                    # smoke: a subset of each experiment, sonnet, once
SMOKE=0 REPEATS=2 tools/proof/suite.sh  # the run above, about 570 sessions
python3 tools/proof/scorecard.py build/proof/suite-<stamp>
```
