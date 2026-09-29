#!/usr/bin/env bash
# Rebuild runs.jsonl and summary.md for a finished run from its raw/*.json,
# so a change to the grading or the summary never needs the agents run again.
#   tools/proof/regrade.sh build/proof/<stamp> [questions.tsv]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$1
questions=${2:-$here/questions.tsv}
: > "$out/runs.jsonl"
tail -n +2 "$questions" | while IFS=$'\t' read -r id _ expected kind; do
  for raw in "$out"/raw/*-"$id"-*.json; do
    [ -f "$raw" ] || continue
    name=$(basename "$raw" .json)          # <model>-<condition>-<id>-<repeat>
    rep=${name##*-}
    prefix=${name%-"$id"-*}                  # <model>-<condition>; a model alias has no dash, a condition may
    model=${prefix%%-*}
    cond=${prefix#*-}
    python3 "$here/record.py" "$cond" "$id" "$rep" "$expected" "$raw" "$model" "${kind:-bullet}" >> "$out/runs.jsonl"
  done
done
python3 "$here/summarize.py" "$out/runs.jsonl" > "$out/summary.md"
echo "regraded $(wc -l < "$out/runs.jsonl") runs -> $out/summary.md"
