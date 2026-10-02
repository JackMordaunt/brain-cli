#!/usr/bin/env python3
"""Two suite directories side by side: what one change did.

  compare.py <before suite dir> <after suite dir>

Prints, per experiment and condition present in both, correct and mean
tokens before and after, on the questions both runs asked. Capture shows
captured and round trip; tasks split covered and uncovered.
"""
import os, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import load, mean

def pct(a, b): return f"{a}/{b}" if b else "-"

def groups(e, rs):
    """-> {(label, condition): [runs]} for comparable slices."""
    g = defaultdict(list)
    for r in rs:
        c = r["condition"]
        if e == "tasks":
            g[("covered" if r.get("covered") else "uncovered", c)].append(r)
        elif e == "capture":
            g[("captured" if r.get("phase") == 1 else "round trip", c)].append(r)
        else:
            g[("", c)].append(r)
    return g

def main(before, after):
    a, b = load(before), load(after)
    print(f"# Before / after\n\nbefore: {os.path.basename(before)}, after: {os.path.basename(after)}. Only questions both runs asked are compared.\n")
    print("| experiment | slice | condition | n | correct before | correct after | tokens before | tokens after | Δ tokens |")
    print("|---|---|---|---:|---:|---:|---:|---:|---:|")
    for e in sorted(set(a) & set(b)):
        ga, gb = groups(e, a[e]), groups(e, b[e])
        for key in sorted(set(ga) & set(gb)):
            label, c = key
            qa = {r["question"] for r in ga[key]}; qb = {r["question"] for r in gb[key]}
            common = qa & qb
            xa = [r for r in ga[key] if r["question"] in common]
            xb = [r for r in gb[key] if r["question"] in common]
            if not xa or not xb:
                continue
            ca, cb = sum(bool(r["correct"]) for r in xa), sum(bool(r["correct"]) for r in xb)
            ta, tb = mean([r["tokens"] for r in xa]), mean([r["tokens"] for r in xb])
            mark = " ↑" if cb > ca else (" ↓" if cb < ca else "")
            print(f"| {e} | {label} | {c} | {len(xb)} | {pct(ca, len(xa))} | {pct(cb, len(xb))}{mark} | {ta:,.0f} | {tb:,.0f} | {tb-ta:+,.0f} |")
    # Per question flips
    print("\n## Flips\n")
    flips = []
    for e in sorted(set(a) & set(b)):
        ia = {(r["condition"], r["question"], r.get("phase", 1)): r for r in a[e]}
        ib = {(r["condition"], r["question"], r.get("phase", 1)): r for r in b[e]}
        for k in sorted(set(ia) & set(ib)):
            if bool(ia[k]["correct"]) != bool(ib[k]["correct"]):
                flips.append(f"- {e} {k[0]} {k[1]}{' p'+str(k[2]) if e=='capture' else ''}: {'miss → ok' if ib[k]['correct'] else 'ok → miss'}; brain calls {ia[k].get('brain_calls', 0)} → {ib[k].get('brain_calls', 0)}")
    print("\n".join(flips) if flips else "none")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
