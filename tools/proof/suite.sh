#!/usr/bin/env bash
# The proof suite: every experiment in AXES.md against the same controls,
# then one scorecard. Smoke by default (a subset of each experiment, sonnet,
# once); SMOKE=0 runs everything.
#
#   tools/proof/suite.sh
#   SMOKE=0 MODELS="sonnet" REPEATS=2 tools/proof/suite.sh
#   EXPERIMENTS="tasks capture" tools/proof/suite.sh
#   PAR=3 tools/proof/suite.sh        # experiments run three at a time
#
# Needs: claude (logged in), python3, build/release/brain (just release),
# and a vault (VAULT=<path>, else `brain locate`). Writes
# build/proof/suite-<stamp>/<experiment>/ and scorecard.md on top.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
smoke=${SMOKE:-1}
par=${PAR:-3}
models=${MODELS:-sonnet}
repeats=${REPEATS:-1}
vault=${VAULT:-$(brain locate)}
brain_bin=${BRAIN:-$root/build/release/brain}
export CLAUDE=${CLAUDE:-$(command -v claude)}
suite=${OUT:-$root/build/proof/suite-$(date -u +%Y%m%dT%H%M%SZ)}
all="lookup paraphrase multihop absent conflict conflict-marked scale-300 scale-3000 tasks capture"
experiments=${EXPERIMENTS:-$all}
[ -x "$brain_bin" ] || { echo "no brain binary at $brain_bin (just release)" >&2; exit 1; }
mkdir -p "$suite/vaults"
echo "suite -> $suite (smoke=$smoke models=$models repeats=$repeats)"
# Every experiment reads the reviewed vault: the markdown and vocabulary
# without AI/INBOX.md, whose unreviewed proposals include the proof's own.
python3 "$here/vaults.py" base "$vault" "$suite/vaults/base" > /dev/null
vault="$suite/vaults/base"

# A smoke run takes the first N rows of a question file.
subset() { # <file> <n>
  if [ "$smoke" = 1 ]; then
    local f; f="$suite/vaults/$(basename "$1")"; head -n $(( $2 + 1 )) "$1" > "$f"; echo "$f"
  else echo "$1"; fi
}
ids() { # <file> <n>: comma-separated first n ids, for behave.py
  if [ "$smoke" = 1 ]; then tail -n +2 "$1" | head -n "$2" | cut -f1 | paste -sd,; else echo ""; fi
}

# CONDS="brain brain-auto" narrows every experiment to those conditions, for
# a before/after on one change.
lookup() { # <name> <questions> <conditions> [vault]
  local name=$1 q=$2 conds=${CONDS:-$3} v=${4:-$vault}
  OUT="$suite/$name" QUESTIONS="$q" CONDITIONS="$conds" MODELS="$models" REPEATS="$repeats" VAULT="$v" BRAIN="$brain_bin" \
    "$here/run.sh" > "$suite/$name.log" 2>&1 || echo "$name: run.sh failed, see $suite/$name.log"
  echo "$name done"
}

run_one() {
  local e=$1
  case "$e" in
    lookup)       lookup lookup "$(subset "$here/questions.tsv" 4)" "vanilla plain brain brain-auto" ;;
    paraphrase)   lookup paraphrase "$(subset "$here/questions-paraphrase.tsv" 4)" "plain brain" ;;
    multihop)     lookup multihop "$(subset "$here/questions-multihop.tsv" 2)" "vanilla plain brain" ;;
    absent)       lookup absent "$(subset "$here/questions-absent.tsv" 4)" "vanilla plain brain"
                  [ "${JUDGE:-1}" = 1 ] && python3 "$here/judge.py" "$suite/absent/runs.jsonl" "$here/questions-absent.tsv" >> "$suite/absent.log" 2>&1 || true
                  python3 "$here/summarize.py" "$suite/absent/runs.jsonl" > "$suite/absent/summary.md" 2>/dev/null || true ;;
    conflict)     python3 "$here/vaults.py" conflict "$vault" "$suite/vaults/conflict" > /dev/null
                  lookup conflict "$(subset "$here/questions-conflict.tsv" 3)" "plain brain" "$suite/vaults/conflict" ;;
    conflict-marked)
                  python3 "$here/vaults.py" conflict --marked "$vault" "$suite/vaults/conflict-marked" > /dev/null
                  lookup conflict-marked "$(subset "$here/questions-conflict.tsv" 3)" "plain brain" "$suite/vaults/conflict-marked" ;;
    scale-*)      local n=${e#scale-}
                  python3 "$here/vaults.py" scale "$n" "$vault" "$suite/vaults/$e" > /dev/null
                  lookup "$e" "$(subset "$here/questions.tsv" "$([ "$smoke" = 1 ] && echo 3 || echo 6)")" "plain brain" "$suite/vaults/$e" ;;
    tasks)        local sel; sel=$(if [ "$smoke" = 1 ]; then echo "hypr-whatsapp,busctl-watch,cl-step,mpv-preview,fizz,dedupe"; fi)
                  for m in $models; do
                    python3 "$here/behave.py" tasks "$here/tasks.tsv" --out "$suite/tasks" --model "$m" --repeats "$repeats" \
                      ${CONDS:+--conditions "$CONDS"} ${sel:+--ids "$sel"} --vault "$vault" --brain "$brain_bin" --jobs "${JOBS:-2}" >> "$suite/tasks.log" 2>&1 || echo "tasks: behave.py failed, see $suite/tasks.log"
                  done; echo "tasks done" ;;
    capture)      local sel; sel=$(ids "$here/capture.tsv" 2)
                  for m in $models; do
                    python3 "$here/behave.py" capture "$here/capture.tsv" --out "$suite/capture" --model "$m" --repeats "$repeats" \
                      ${CONDS:+--conditions "$CONDS"} ${sel:+--ids "$sel"} --vault "$vault" --brain "$brain_bin" --jobs "${JOBS:-2}" >> "$suite/capture.log" 2>&1 || echo "capture: behave.py failed, see $suite/capture.log"
                  done; echo "capture done" ;;
    *) echo "unknown experiment $e" >&2 ;;
  esac
}

# Experiments run $par at a time; each has its own work directory.
running=0
for e in $experiments; do
  run_one "$e" &
  running=$((running + 1))
  if [ "$running" -ge "$par" ]; then wait -n; running=$((running - 1)); fi
done
wait
python3 "$here/scorecard.py" "$suite" > "$suite/scorecard.md"
echo "wrote $suite/scorecard.md"
