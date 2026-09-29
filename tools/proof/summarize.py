#!/usr/bin/env python3
"""runs.jsonl -> summary.md: per condition, then per question."""
import json, statistics, sys
from collections import defaultdict
runs = []
for f in sys.argv[1:]:
    runs += [json.loads(l) for l in open(f) if l.strip()]
for r in runs:
    r.setdefault("model", "sonnet")
conds, models = [], []
for r in runs:
    if r["condition"] not in conds:
        conds.append(r["condition"])
    if r["model"] not in models:
        models.append(r["model"])
by = defaultdict(list)
for r in runs:
    by[r["model"], r["condition"]].append(r)
def mean(xs): return statistics.mean(xs) if xs else 0
def med(xs): return statistics.median(xs) if xs else 0
# Every turn is one request carrying the whole conversation so far, the
# system prompt included, and that prompt is the same in every condition. A
# model's smallest one-turn run is that prompt alone; what a run added beyond
# it is its tokens less that prompt once per turn.
prompt = {}
for m in models:
    one_turn = [r["tokens"] for r in runs if r["model"] == m and r["turns"] == 1 and r["tokens"] > 0]
    prompt[m] = min(one_turn) if one_turn else 0
for r in runs:
    r["extra"] = max(r["tokens"] - r["turns"] * prompt[r["model"]], 0)
print("# Proof: what a lookup costs an agent\n")
print(f"{len(runs)} runs, {len({r['question'] for r in runs})} questions, {max((r['repeat'] for r in runs), default=0)} repeat(s), models: {', '.join(models)}. Tokens are every token the model processed across the run's turns: input, cache reads, cache writes, output.\n")
print("Beyond the prompt: what a run added past the fixed system prompt (a model's smallest one-turn run: " + ", ".join(f"{m} {prompt[m]:,}" for m in models) + "), which every condition sends again on every turn.\n")
print("| model | condition | runs | correct | tokens mean | beyond the prompt mean | beyond the prompt median | turns mean | cost mean | seconds mean |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
for m in models:
    for c in conds:
        rs = by[m, c]
        if not rs:
            continue
        ok = sum(r["correct"] for r in rs)
        print(f"| {m} | {c} | {len(rs)} | {ok}/{len(rs)} ({100*ok/len(rs):.0f}%) | {mean([r['tokens'] for r in rs]):,.0f} | {mean([r['extra'] for r in rs]):,.0f} | {med([r['extra'] for r in rs]):,.0f} | {mean([r['turns'] for r in rs]):.1f} | ${mean([r['cost'] for r in rs]):.3f} | {mean([r['seconds'] for r in rs]):.1f} |")
qs = []
for r in runs:
    if r["question"] not in qs:
        qs.append(r["question"])
for m in models:
    print(f"\n## {m}, per question (beyond the prompt, mean; correct/runs)\n")
    print("| question | " + " | ".join(conds) + " |")
    print("|---|" + "---:|" * len(conds))
    for q in qs:
        cells = []
        for c in conds:
            rs = [r for r in by[m, c] if r["question"] == q]
            if not rs:
                cells.append("")
                continue
            cells.append(f"{mean([r['extra'] for r in rs]):,.0f} ({sum(r['correct'] for r in rs)}/{len(rs)})")
        print(f"| {q} | " + " | ".join(cells) + " |")
errs = [r for r in runs if r["error"]]
if errs:
    print(f"\n{len(errs)} run(s) reported an error; see runs.jsonl.")
