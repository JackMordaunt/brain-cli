#!/usr/bin/env python3
"""runs.jsonl -> summary.md: per condition, then per question."""
import json, os, statistics, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import mean
runs = []
for f in sys.argv[1:]:
    runs += [json.loads(l) for l in open(f) if l.strip()]
for r in runs:
    r.setdefault("model", "sonnet")
    r.setdefault("kind", "bullet")
conds, models = [], []
for r in runs:
    if r["condition"] not in conds:
        conds.append(r["condition"])
    if r["model"] not in models:
        models.append(r["model"])
by = defaultdict(list)
for r in runs:
    by[r["model"], r["condition"]].append(r)
def med(xs): return statistics.median(xs) if xs else 0
print("# Proof: what a lookup costs an agent\n")
print(f"{len(runs)} runs, {len({r['question'] for r in runs})} questions, {max((r['repeat'] for r in runs), default=0)} repeat(s), models: {', '.join(models)}. Tokens are every token the model processed across the run's turns: input, cache reads, cache writes, output.\n")
print("| model | condition | runs | correct | tokens mean | tokens median | output mean | turns mean | cost mean | seconds mean |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
for m in models:
    for c in conds:
        rs = by[m, c]
        if not rs:
            continue
        ok = sum(r["correct"] for r in rs)
        print(f"| {m} | {c} | {len(rs)} | {ok}/{len(rs)} ({100*ok/len(rs):.0f}%) | {mean([r['tokens'] for r in rs]):,.0f} | {med([r['tokens'] for r in rs]):,.0f} | {mean([r['output'] for r in rs]):,.0f} | {mean([r['turns'] for r in rs]):.1f} | ${mean([r['cost'] for r in rs]):.3f} | {mean([r['seconds'] for r in rs]):.1f} |")
kinds = []
for r in runs:
    if r["kind"] not in kinds:
        kinds.append(r["kind"])
if len(kinds) > 1:
    print("\n## By kind of question: answer in a bullet, or only in a note\n")
    print("| model | condition | " + " | ".join(f"{k}: correct" for k in kinds) + " | " + " | ".join(f"{k}: tokens" for k in kinds) + " |")
    print("|---|---|" + "---:|" * (2 * len(kinds)))
    for m in models:
        for c in conds:
            rs = by[m, c]
            if not rs:
                continue
            cells = []
            for k in kinds:
                x = [r for r in rs if r["kind"] == k]
                cells.append(f"{sum(r['correct'] for r in x)}/{len(x)}" if x else "")
            for k in kinds:
                x = [r for r in rs if r["kind"] == k]
                cells.append(f"{mean([r['tokens'] for r in x]):,.0f}" if x else "")
            print(f"| {m} | {c} | " + " | ".join(cells) + " |")
qs = []
for r in runs:
    if r["question"] not in qs:
        qs.append(r["question"])
for m in models:
    print(f"\n## {m}, per question (tokens mean; correct/runs)\n")
    print("| question | " + " | ".join(conds) + " |")
    print("|---|" + "---:|" * len(conds))
    for q in qs:
        cells = []
        for c in conds:
            rs = [r for r in by[m, c] if r["question"] == q]
            if not rs:
                cells.append("")
                continue
            cells.append(f"{mean([r['tokens'] for r in rs]):,.0f} ({sum(r['correct'] for r in rs)}/{len(rs)})")
        print(f"| {q} | " + " | ".join(cells) + " |")
errs = [r for r in runs if r["error"]]
if errs:
    print(f"\n{len(errs)} run(s) reported an error; see runs.jsonl.")
