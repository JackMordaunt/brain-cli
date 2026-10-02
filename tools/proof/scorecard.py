#!/usr/bin/env python3
"""suite dir -> scorecard.md: one table per experiment, then the axes.

  scorecard.py build/proof/suite-<stamp>

Reads every <experiment>/runs.jsonl under the suite directory. The
experiment is the directory name; AXES.md says which axis each one scores.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import load, mean, pct

def order(xs):
    seen = []
    for x in xs:
        if x not in seen:
            seen.append(x)
    return seen
COND_ORDER = ["vanilla", "plain", "brain", "brain-auto"]
def conds(rs): return sorted(order(r["condition"] for r in rs), key=lambda c: (COND_ORDER.index(c) if c in COND_ORDER else 9, c))

def row(rs, extra=()):
    ok = sum(bool(r.get("correct")) for r in rs)
    cells = [str(len(rs)), pct(ok, len(rs)), f"{mean([r['tokens'] for r in rs]):,.0f}", f"{mean([r['turns'] for r in rs]):.1f}",
             f"${mean([r['cost'] for r in rs]):.3f}", f"{mean([r['seconds'] for r in rs]):.0f}"]
    return cells + list(extra)

def table(head, rows):
    print("| " + " | ".join(head) + " |")
    print("|" + "|".join("---:" if i > 1 else "---" for i in range(len(head))) + "|")
    for r in rows:
        print("| " + " | ".join(r) + " |")
    print()

BASE = ["model", "condition", "runs", "correct", "tokens", "turns", "cost", "s"]

def experiment(name, rs):
    print(f"## {name}\n")
    models = order(r["model"] for r in rs)
    kinds = order(r.get("kind", "") for r in rs)
    has_trap = any("trap" in r and r.get("trap") is not None for r in rs) and any(r.get("trap") for r in rs) or name.startswith("conflict") or name == "absent"
    has_judge = any(r.get("judge") is not None for r in rs)
    if name == "capture":
        rows = []
        for m in models:
            for c in conds(rs):
                p1 = [r for r in rs if r["model"] == m and r["condition"] == c and r.get("phase") == 1]
                p2 = [r for r in rs if r["model"] == m and r["condition"] == c and r.get("phase") == 2]
                if not p1:
                    continue
                cap = sum(bool(r.get("captured")) for r in p1)
                lint = [r for r in p1 if r.get("captured")]
                lint_ok = sum(bool(r.get("lint_ok")) for r in lint)
                local = sum(bool(r.get("captured_local")) for r in p1)
                rt = sum(bool(r.get("correct")) for r in p2)
                asked = sum(bool(r.get("settle_asked")) for r in p1)
                rows.append([m, c, str(len(p1)), pct(cap, len(p1)), pct(lint_ok, len(lint)), pct(asked, len(p1)) if c == "brain-auto" else "", pct(local, len(p1)), pct(rt, len(p2)),
                             f"{mean([r['tokens'] for r in p1]):,.0f}", f"{mean([r['tokens'] for r in p2]):,.0f}",
                             f"${mean([r['cost'] for r in p1 + p2]):.3f}"])
        table(["model", "condition", "runs", "captured (A6)", "lint ok", "settle asked", "written locally", "round trip (A7)", "tokens p1", "tokens p2", "cost both"], rows)
        return
    if name == "tasks":
        rows = []
        for m in models:
            for c in conds(rs):
                for cov, label in ((True, "covered (A4)"), (False, "uncovered (A5)")):
                    x = [r for r in rs if r["model"] == m and r["condition"] == c and bool(r.get("covered")) == cov]
                    if x:
                        rows.append([m, c, label] + row(x))
        table(["model", "condition", "rows"] + BASE[2:], rows)
        return
    rows = []
    for m in models:
        for c in conds(rs):
            x = [r for r in rs if r["model"] == m and r["condition"] == c]
            if not x:
                continue
            extra = []
            if has_trap:
                extra.append(pct(sum(bool(r.get("trap")) for r in x), len(x)))
            if has_judge:
                j = [r for r in x if r.get("judge") is not None]
                if name.startswith("conflict"):
                    extra.append(pct(sum(r["judge"] == "STALE" for r in j), len(j)))
                else:
                    extra.append(pct(sum(bool(r["judge"]) for r in j), len(j)))
            rows.append([m, c] + row(x, extra))
    judge_head = "judge: asserted stale" if name.startswith("conflict") else "judge: abstained"
    head = BASE + (["trapped (mention)"] if has_trap else []) + ([judge_head] if has_judge else [])
    table(head, rows)
    if len(kinds) > 1:
        rows = []
        for m in models:
            for c in conds(rs):
                for k in kinds:
                    x = [r for r in rs if r["model"] == m and r["condition"] == c and r.get("kind") == k]
                    if x:
                        rows.append([m, c, k] + row(x))
        table(["model", "condition", "kind"] + BASE[2:], rows)
    qs = order(r["question"] for r in rs)
    cs = conds(rs)
    rows = []
    for q in qs:
        cells = [q]
        for c in cs:
            x = [r for r in rs if r["question"] == q and r["condition"] == c]
            cells.append(f"{sum(bool(r.get('correct')) for r in x)}/{len(x)} {mean([r['tokens'] for r in x]):,.0f}" if x else "")
        rows.append(cells)
    print("<details><summary>per question (correct/runs, tokens)</summary>\n")
    table(["question"] + cs, rows)
    print("</details>\n")

def axes(runs):
    print("## Axes\n")
    def acc(e, c, pred=lambda r: True):
        x = [r for r in runs.get(e, []) if r["condition"] == c and pred(r)]
        return (sum(bool(r.get("correct")) for r in x), len(x), mean([r["tokens"] for r in x]))
    def fmt(t): return f"{pct(t[0], t[1])}, {t[2]:,.0f} tok" if t[1] else "not run"
    lines = []
    if "lookup" in runs:
        lines.append(("A1 recall", "lookup", " / ".join(f"{c}: {fmt(acc('lookup', c))}" for c in conds(runs["lookup"]))))
        p, b = acc("lookup", "plain"), acc("lookup", "brain")
        if p[1] and b[1] and b[2]:
            lines.append(("A2 cost", "lookup", f"plain / brain tokens = {p[2]/b[2]:.1f}x"))
    if "absent" in runs:
        judged = any(r.get("judge") is not None for r in runs["absent"])
        def trap(c):
            x = [r for r in runs["absent"] if r["condition"] == c]
            if judged:
                j = [r for r in x if r.get("judge") is not None]
                return f"{c}: abstained {pct(sum(bool(r['judge']) for r in j), len(j))} (judge), trapped {pct(sum(bool(r.get('trap')) for r in x), len(x))} (regex)"
            return f"{c}: abstained {pct(sum(bool(r.get('correct')) for r in x), len(x))}, trapped {pct(sum(bool(r.get('trap')) for r in x), len(x))}"
        lines.append(("A3 calibration", "absent", " / ".join(trap(c) for c in conds(runs["absent"]))))
    if "tasks" in runs:
        lines.append(("A4 uptake", "tasks, covered", " / ".join(f"{c}: {fmt(acc('tasks', c, lambda r: r.get('covered')))}" for c in conds(runs["tasks"]))))
        v = acc("tasks", "vanilla", lambda r: not r.get("covered"))
        for c in conds(runs["tasks"]):
            if c == "vanilla":
                continue
            x = acc("tasks", c, lambda r: not r.get("covered"))
            if v[1] and x[1]:
                lines.append(("A5 overhead", f"tasks, uncovered, {c}", f"{x[2]-v[2]:+,.0f} tok vs vanilla; correct {pct(x[0], x[1])} vs {pct(v[0], v[1])}"))
    if "capture" in runs:
        for c in conds(runs["capture"]):
            p1 = [r for r in runs["capture"] if r["condition"] == c and r.get("phase") == 1]
            p2 = [r for r in runs["capture"] if r["condition"] == c and r.get("phase") == 2]
            if p1:
                lines.append(("A6/A7 capture, round trip", f"capture, {c}", f"captured {pct(sum(bool(r.get('captured')) for r in p1), len(p1))}, round trip {pct(sum(bool(r.get('correct')) for r in p2), len(p2))}"))
    for e in ("conflict", "conflict-marked", "conflict-tended"):
        if e in runs:
            x = runs[e]
            judged = any(r.get("judge") for r in x)
            def cell(c):
                y = [r for r in x if r["condition"] == c]
                if judged:
                    j = [r for r in y if r.get("judge")]
                    return f"{c}: asserted stale {pct(sum(r['judge'] == 'STALE' for r in j), len(j))} (judge), mentioned {pct(sum(bool(r.get('trap')) for r in y), len(y))}"
                return f"{c}: correct {pct(sum(bool(r.get('correct')) for r in y), len(y))}, trapped {pct(sum(bool(r.get('trap')) for r in y), len(y))}"
            lines.append(("A8 stale note", e, " / ".join(cell(c) for c in conds(x))))
    if "paraphrase" in runs and "lookup" in runs:
        ids = {r["question"] for r in runs["paraphrase"]}
        for c in conds(runs["paraphrase"]):
            a = acc("paraphrase", c); b = acc("lookup", c, lambda r: r["question"] in ids)
            lines.append(("A8 paraphrase", f"paraphrase vs lookup, {c}", f"{pct(a[0], a[1])} vs {pct(b[0], b[1])}; {a[2]:,.0f} vs {b[2]:,.0f} tok"))
    scales = sorted((e for e in runs if e.startswith("scale-")), key=lambda e: int(e[6:]))
    for c in ("plain", "brain"):
        parts = [f"{e[6:]}: {fmt(acc(e, c))}" for e in scales if acc(e, c)[1]]
        if parts:
            lines.append(("A8 vault size", f"scale, {c}", " / ".join(parts)))
    table(["axis", "experiment", "result"], [list(l) for l in lines])

def main(suite):
    runs = load(suite)
    total = sum(len(v) for v in runs.values())
    models = order(r["model"] for v in runs.values() for r in v)
    print(f"# Proof suite scorecard\n\n{os.path.basename(suite)}: {total} runs over {len(runs)} experiments; models: {', '.join(models)}. "
          "Tokens are every token the run processed (input, cache reads, cache writes, output). Axes are defined in tools/proof/AXES.md.\n")
    axes(runs)
    for e, rs in runs.items():
        experiment(e, rs)
    errs = [(e, r) for e, v in runs.items() for r in v if r.get("error")]
    if errs:
        print(f"{len(errs)} run(s) reported an error:\n")
        for e, r in errs[:20]:
            print(f"- {e} {r['condition']} {r['question']}: {r['error'][:120]}")

if __name__ == "__main__":
    main(sys.argv[1])
