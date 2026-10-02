#!/usr/bin/env bash
# What a lookup costs an agent, measured on real sessions: the same questions
# asked of Claude Code with no notes (vanilla), with the vault as plain
# markdown it must search itself (plain), and with the vault behind `brain`
# (brain). Each run is one `claude -p` in an isolated home that holds only
# credentials, so no global instructions reach the agent; the working
# directory's CLAUDE.md is the whole difference between conditions.
#
#   tools/proof/run.sh                # every question, every condition, once, on sonnet
#   REPEATS=3 MODELS="haiku sonnet opus fable" CONDITIONS="plain brain" tools/proof/run.sh
#   CONDITIONS="brain brain-notes brain-source brain-both" tools/proof/run.sh   # find's knobs
#   CONDITIONS="brain-open" tools/proof/run.sh   # brain, and the agent may open a note find names
#   CONDITIONS="brain-auto" tools/proof/run.sh   # no instructions at all; the hooks prime each prompt
#   CONDITIONS="brain-weighted" tools/proof/run.sh   # find boosts bullets this machine's sessions used
#   CONDITIONS="brain-auto brain-auto-b300 brain-auto-b1200" tools/proof/run.sh   # prime's budget
#
# Needs: claude (logged in), python3, a built build/release/brain, and a
# vault (VAULT=<path>, else `brain locate`). A fifth questions column, trap,
# is a regex a wrong answer falls into (a stale or made-up specific); matching
# it is a miss. Writes build/proof/<stamp>/:
# raw/*.json per run, runs.jsonl, summary.md.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
repeats=${REPEATS:-1}
models=${MODELS:-${MODEL:-sonnet}}
conditions=${CONDITIONS:-vanilla plain brain}
questions=${QUESTIONS:-$here/questions.tsv}
vault=${VAULT:-$(brain locate)}
brain_bin=${BRAIN:-$root/build/release/brain}
out=$(realpath -m "${OUT:-$root/build/proof/$(date -u +%Y%m%dT%H%M%SZ)}")  # absolute: runs cd elsewhere
CLAUDE=${CLAUDE:-$(command -v claude)}
[ -x "$brain_bin" ] || { echo "no brain binary at $brain_bin (just release)" >&2; exit 1; }
[ -f "$questions" ] || { echo "no questions at $questions" >&2; exit 1; }
mkdir -p "$out/raw"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/.claude" "$work/home-auto/.claude" "$work/bin" "$work/state"
cp "$HOME/.claude/.credentials.json" "$work/home/.claude/"
cp "$HOME/.claude/.credentials.json" "$work/home-auto/.claude/"
# The vault, without its history, where every condition that has notes reads it.
mkdir -p "$work/vault"
(cd "$vault" && find . -name '*.md' -not -path './.git/*' -print0 | cpio -0 -pdm --quiet "$work/vault")
cp "$vault/AI/synonyms.tsv" "$work/vault/AI/" 2>/dev/null || true
ln -s "$brain_bin" "$work/bin/brain"
# brain-weighted ranks by what this machine's sessions used, so the proof's
# index starts from the machine's own log, which reindex carries across.
if [[ " $conditions " == *" brain-weighted "* ]]; then
  cp "${XDG_STATE_HOME:-$HOME/.local/state}/brain/brain.db" "$work/state/brain.db" 2>/dev/null || true
fi
BRAIN_VAULT="$work/vault" BRAIN_STATE="$work/state" "$brain_bin" reindex >/dev/null
# brain-auto's home carries the three hooks install registers and nothing
# else: the pack at session start, prime on every prompt, settle on stop.
HOME="$work/home-auto" BRAIN_EXE=brain BRAIN_VAULT="$work/vault" BRAIN_STATE="$work/state" "$brain_bin" hooks on >/dev/null

mkdir -p "$work/vanilla" "$work/plain" "$work/brain" "$work/brain-auto"
cat > "$work/vanilla/CLAUDE.md" <<'MD'
This is an empty scratch directory with no notes. Answer the question from what you know; if you do not know, say so in one sentence.
MD
cat > "$work/plain/CLAUDE.md" <<MD
Your notes live at $work/vault. AI/MEMORY.md, AI/LEARNINGS.md and AI/TUNINGS.md hold one fact per line in the shape \`- **handle** (aliases: ...) — fact — source — date\`; the other folders hold longer notes. Search the notes before answering, and prefer what they say to what you assume.
MD
# brain: what `brain export` opens a hook-less agent's file with (ASK_HEAD),
# plus the lookup proof's own line about not opening the files.
cat > "$work/brain/CLAUDE.md" <<'MD'
Memory for this repository, from the Brain vault (`brain locate`). Before acting on a task, run `brain find <key terms>` (a tool, an error, a file) and act on what comes back. When work settles a durable fact, `brain propose '- **handle** (aliases: ...) — fact'` records it for a person to review. Ask brain before answering, and prefer what it says to what you assume. Do not read the vault's files directly.
MD
# brain-auto: the block `brain install` writes, with the hooks: the real
# install. Before 2026-10-02 14:50Z this was the vanilla text plus hooks.
cat > "$work/brain-auto/CLAUDE.md" <<'MD'
The Brain is this machine's shared agent memory. `brain locate` prints its path,
`brain find <handle>` searches it, and `brain recall <terms>` searches what was
said in past agent conversations. Do not hard-code the path. A session opens
with `brain pack`, the vault's bullets about this repository. When work settles
a durable fact, `brain propose '- **handle** (aliases: ...) — fact'` records it
for a person to review; never edit the vault's core files directly.
MD
# brain-open: the block `brain install` writes, which forbids nothing; the
# agent may open a note that find points at.
mkdir -p "$work/brain-open"
cat > "$work/brain-open/CLAUDE.md" <<'MD'
The Brain is this machine's shared agent memory. `brain locate` prints its path, `brain find <terms>` searches it, and `brain recall <terms>` searches what was said in past agent conversations. Ask brain before answering, and prefer what it says to what you assume. When find points at a line in a longer note, open that note.
MD

tools=(Read Grep Glob 'Bash(brain:*)' 'Bash(grep:*)' 'Bash(rg:*)' 'Bash(cat:*)' 'Bash(ls:*)' 'Bash(find:*)' 'Bash(head:*)' 'Bash(tail:*)' 'Bash(sed:*)' 'Bash(wc:*)')
n=0
for model in $models; do
for r in $(seq 1 "$repeats"); do
  tail -n +2 "$questions" | while IFS=$'\t' read -r id question expected kind trap; do
    for c in $conditions; do
      n=$((n + 1))
      raw="$out/raw/$model-$c-$id-$r.json"
      path="/usr/bin:/bin"
      dir="$c"
      # brain-* conditions are brain with a knob turned: brain-notes returns
      # notes only when bullets fall short, brain-source keeps the source
      # clause, brain-both does both; plain brain is the shipped behaviour.
      notes=always
      with_source=""
      home="$work/home"
      rank=""
      prime_budget=""
      case "$c" in
        brain) path="$work/bin:$path" ;;
        brain-auto) path="$work/bin:$path"; home="$work/home-auto" ;;
        # brain-auto with prime's budget turned: 300 or 1200 tokens a prompt against the 600 default.
        brain-auto-b*) dir=brain-auto; path="$work/bin:$path"; home="$work/home-auto"; prime_budget=${c#brain-auto-b} ;;
        brain-weighted) dir=brain; path="$work/bin:$path"; rank=weighted ;;
        brain-open) path="$work/bin:$path" ;;
        brain-notes) dir=brain; path="$work/bin:$path"; notes=short ;;
        brain-source) dir=brain; path="$work/bin:$path"; with_source=source ;;
        brain-both) dir=brain; path="$work/bin:$path"; notes=short; with_source=source ;;
      esac
      # plain reads the vault with Claude Code's own tools. One smoke session
      # (2026-10-02) refused the vault path as outside the working directory,
      # so the vault is added as one and a refusal never counts against plain.
      adddir=()
      [ "$c" = plain ] && adddir=(--add-dir "$work/vault")
      (cd "$work/$dir" && env -i HOME="$home" PATH="$path" TERM=dumb LANG=C.UTF-8 \
          BRAIN_VAULT="$work/vault" BRAIN_STATE="$work/state" BRAIN_NO_UPDATE=1 \
          BRAIN_NOTES="$notes" BRAIN_TERSE="$with_source" BRAIN_RANK="$rank" BRAIN_PRIME_BUDGET="$prime_budget" \
          "$CLAUDE" -p "$question" --output-format stream-json --verbose --model "$model" --max-turns 12 "${adddir[@]}" \
          --max-budget-usd 1 --no-session-persistence \
          --append-system-prompt "Answer in at most three sentences." \
          --allowedTools "${tools[@]}" < /dev/null > "$raw" 2>"$raw.err") || true
      python3 "$here/record.py" "$c" "$id" "$r" "$expected" "$raw" "$model" "${kind:-bullet}" "${trap:-}" >> "$out/runs.jsonl"
      printf '%s %s %s r%s: %s\n' "$model" "$c" "$id" "$r" "$(tail -n 1 "$out/runs.jsonl" | python3 -c 'import sys,json; d=json.loads(sys.stdin.readline()); print(("ok " if d["correct"] else "MISS"), d["tokens"], "tokens,", d["turns"], "turns", "$%.3f" % d["cost"])')"
    done
  done
done
done
python3 "$here/summarize.py" "$out/runs.jsonl" > "$out/summary.md"
echo "wrote $out/summary.md"
