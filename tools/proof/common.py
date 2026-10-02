"""What the proof's readers share: loading a suite's records, a mean that
tolerates an empty list, and a count as "k/n (p%)"."""
import json, os, statistics
from collections import defaultdict

def mean(xs):
    return statistics.mean(xs) if xs else 0

def pct(a, b):
    return f"{a}/{b} ({100*a/b:.0f}%)" if b else ""

def load(suite):
    """Every <experiment>/runs.jsonl under a suite directory, keyed by experiment."""
    runs = defaultdict(list)
    for e in sorted(os.listdir(suite)):
        p = os.path.join(suite, e, "runs.jsonl")
        if os.path.isfile(p):
            for l in open(p):
                if l.strip():
                    r = json.loads(l)
                    r.setdefault("model", "sonnet")
                    runs[e].append(r)
    return runs
