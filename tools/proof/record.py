#!/usr/bin/env python3
"""One run of the proof, as a JSON line: what it cost and whether it was right."""
import json, re, sys
cond, qid, rep, expected, raw = sys.argv[1:6]
model = sys.argv[6] if len(sys.argv) > 6 else "sonnet"
kind = sys.argv[7] if len(sys.argv) > 7 else "bullet"
rec = {"model": model, "condition": cond, "question": qid, "kind": kind, "repeat": int(rep), "correct": False,
       "tokens": 0, "input": 0, "cache_read": 0, "cache_write": 0, "output": 0,
       "turns": 0, "cost": 0.0, "seconds": 0.0, "answer": "", "error": ""}
try:
    d = json.load(open(raw))
    u = d.get("usage", {})
    inp = int(u.get("input_tokens", 0))
    cache_read = int(u.get("cache_read_input_tokens", 0))
    cache_write = int(u.get("cache_creation_input_tokens", 0))
    output = int(u.get("output_tokens", 0))
    rec.update(input=inp, cache_read=cache_read, cache_write=cache_write, output=output,
               tokens=inp + cache_read + cache_write + output)
    rec["turns"] = d.get("num_turns", 0)
    rec["cost"] = d.get("total_cost_usd", 0.0)
    rec["seconds"] = d.get("duration_ms", 0) / 1000
    answer = d.get("result") or ""
    rec["answer"] = answer[:600]
    # The alias names a family; `modelUsage` in the JSON names each model the
    # run used with its cost, so the one that cost the most did the work.
    mu = d.get("modelUsage", {})
    if mu:
        rec["model_id"] = max(mu, key=lambda k: mu[k].get("costUSD", 0))
    rec["correct"] = re.search(expected, answer, re.I | re.S) is not None
    if d.get("is_error"):
        rec["error"] = str(d.get("result", ""))[:200]
    elif not answer.strip():
        rec["error"] = "no answer (turn cap or budget reached)"
except Exception as e:  # a run that produced no JSON is a failed run, recorded as such
    rec["error"] = f"{type(e).__name__}: {e}"
print(json.dumps(rec, ensure_ascii=False))
