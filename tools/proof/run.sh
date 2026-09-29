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
#
# Needs: claude (logged in), python3, a built build/release/brain, and a
# vault (VAULT=<path>, else `brain locate`). Writes build/proof/<stamp>/:
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
out=${OUT:-$root/build/proof/$(date -u +%Y%m%dT%H%M%SZ)}
[ -x "$brain_bin" ] || { echo "no brain binary at $brain_bin (just release)" >&2; exit 1; }
[ -f "$questions" ] || { echo "no questions at $questions" >&2; exit 1; }
mkdir -p "$out/raw"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/.claude" "$work/bin" "$work/state"
cp "$HOME/.claude/.credentials.json" "$work/home/.claude/"
# The vault, without its history, where every condition that has notes reads it.
mkdir -p "$work/vault"
(cd "$vault" && find . -name '*.md' -not -path './.git/*' -print0 | cpio -0 -pdm --quiet "$work/vault")
cp "$vault/AI/synonyms.tsv" "$work/vault/AI/" 2>/dev/null || true
ln -s "$brain_bin" "$work/bin/brain"
BRAIN_VAULT="$work/vault" BRAIN_STATE="$work/state" "$brain_bin" reindex >/dev/null

mkdir -p "$work/vanilla" "$work/plain" "$work/brain"
cat > "$work/vanilla/CLAUDE.md" <<'MD'
This is an empty scratch directory with no notes. Answer the question from what you know; if you do not know, say so in one sentence.
MD
cat > "$work/plain/CLAUDE.md" <<MD
Your notes live at $work/vault. AI/MEMORY.md, AI/LEARNINGS.md and AI/TUNINGS.md hold one fact per line in the shape \`- **handle** (aliases: ...) — fact — source — date\`; the other folders hold longer notes. Search the notes before answering, and prefer what they say to what you assume.
MD
cat > "$work/brain/CLAUDE.md" <<'MD'
The Brain is this machine's shared agent memory. `brain locate` prints its path, `brain find <terms>` searches it, and `brain recall <terms>` searches what was said in past agent conversations. Ask brain before answering, and prefer what it says to what you assume. Do not read the vault's files directly.
MD

tools=(Read Grep Glob 'Bash(brain:*)' 'Bash(grep:*)' 'Bash(rg:*)' 'Bash(cat:*)' 'Bash(ls:*)' 'Bash(find:*)' 'Bash(head:*)' 'Bash(tail:*)' 'Bash(sed:*)' 'Bash(wc:*)')
n=0
for model in $models; do
for r in $(seq 1 "$repeats"); do
  tail -n +2 "$questions" | while IFS=$'\t' read -r id question expected kind; do
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
      case "$c" in
        brain) path="$work/bin:$path" ;;
        brain-notes) dir=brain; path="$work/bin:$path"; notes=short ;;
        brain-source) dir=brain; path="$work/bin:$path"; with_source=source ;;
        brain-both) dir=brain; path="$work/bin:$path"; notes=short; with_source=source ;;
      esac
      (cd "$work/$dir" && env -i HOME="$work/home" PATH="$path" TERM=dumb LANG=C.UTF-8 \
          BRAIN_VAULT="$work/vault" BRAIN_STATE="$work/state" BRAIN_NO_UPDATE=1 \
          BRAIN_NOTES="$notes" BRAIN_TERSE="$with_source" \
          claude -p "$question" --output-format json --model "$model" --max-turns 12 \
          --max-budget-usd 1 --no-session-persistence \
          --append-system-prompt "Answer in at most three sentences." \
          --allowedTools "${tools[@]}" < /dev/null > "$raw" 2>"$raw.err") || true
      python3 "$here/record.py" "$c" "$id" "$r" "$expected" "$raw" "$model" "${kind:-bullet}" >> "$out/runs.jsonl"
      printf '%s %s %s r%s: %s\n' "$model" "$c" "$id" "$r" "$(tail -n 1 "$out/runs.jsonl" | python3 -c 'import sys,json; d=json.loads(sys.stdin.readline()); print(("ok " if d["correct"] else "MISS"), d["tokens"], "tokens,", d["turns"], "turns", "$%.3f" % d["cost"])')"
    done
  done
done
done
python3 "$here/summarize.py" "$out/runs.jsonl" > "$out/summary.md"
echo "wrote $out/summary.md"
