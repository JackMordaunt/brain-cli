#!/usr/bin/env python3
"""One run of the proof, as a JSON line: what it cost and whether it was right.

  record.py <condition> <question-id> <repeat> <expected-regex> <raw> [model] [kind] [trap-regex]

The raw file is what `claude -p --output-format stream-json --verbose` wrote
(one JSON event per line; the result event carries usage and the answer), or
the older single-object `--output-format json`. load_run reads either and
also lists the tool calls the agent made, so a record says whether it asked
brain, grepped, read a file or proposed.
"""
import json, re, sys

def brief(name, inp):
    if name == "Bash":
        return "Bash:" + str(inp.get("command", ""))[:120]
    if name in ("Read", "Write", "Edit"):
        return f"{name}:" + str(inp.get("file_path", ""))[-80:]
    if name == "Grep":
        return "Grep:" + str(inp.get("pattern", ""))[:60]
    if name == "Glob":
        return "Glob:" + str(inp.get("pattern", ""))[:60]
    return name

def load_run(path):
    """-> (result dict, tool call briefs, permission denials)."""
    text = open(path, encoding="utf-8", errors="replace").read()
    tools, result = [], None
    stripped = text.lstrip()
    if stripped.startswith('{"type"'):
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = d.get("type")
            if t == "assistant":
                for b in d.get("message", {}).get("content", []):
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        tools.append(brief(b.get("name", "?"), b.get("input") or {}))
            elif t == "result":
                result = d
        if result is None:
            raise ValueError("no result event")
    else:
        result = json.loads(text)
    denials = [brief(x.get("tool_name", "?"), x.get("tool_input") or {}) for x in result.get("permission_denials") or []]
    return result, tools, denials

def measure(d, tools, denials):
    u = d.get("usage", {})
    rec = {"input": int(u.get("input_tokens", 0)), "cache_read": int(u.get("cache_read_input_tokens", 0)),
           "cache_write": int(u.get("cache_creation_input_tokens", 0)), "output": int(u.get("output_tokens", 0)),
           "turns": d.get("num_turns", 0), "cost": d.get("total_cost_usd", 0.0), "seconds": d.get("duration_ms", 0) / 1000,
           "answer": (d.get("result") or "")[:1200], "_full": d.get("result") or "", "tools": tools, "denials": denials,
           "brain_calls": sum(1 for t in tools if t.startswith("Bash:brain")),
           "file_reads": sum(1 for t in tools if t.startswith(("Read:", "Grep:", "Glob:", "Bash:grep", "Bash:rg", "Bash:cat"))),
           "error": ""}
    rec["tokens"] = rec["input"] + rec["cache_read"] + rec["cache_write"] + rec["output"]
    # The alias names a family. In the runs seen so far, `modelUsage` listed
    # the model under test beside a small haiku entry, so the costliest
    # entry is taken as the one that answered.
    mu = d.get("modelUsage", {})
    if mu:
        rec["model_id"] = max(mu, key=lambda k: mu[k].get("costUSD", 0))
    if d.get("is_error"):
        rec["error"] = str(d.get("result", ""))[:200]
    elif not rec["answer"].strip():
        rec["error"] = "no answer (turn cap or budget reached)"
    return rec

def main():
    cond, qid, rep, expected, raw = sys.argv[1:6]
    model = sys.argv[6] if len(sys.argv) > 6 else "sonnet"
    kind = sys.argv[7] if len(sys.argv) > 7 else "bullet"
    trap = sys.argv[8] if len(sys.argv) > 8 else ""
    rec = {"model": model, "condition": cond, "question": qid, "kind": kind, "repeat": int(rep), "correct": False,
           "tokens": 0, "input": 0, "cache_read": 0, "cache_write": 0, "output": 0,
           "turns": 0, "cost": 0.0, "seconds": 0.0, "answer": "", "error": "", "trap": False, "tools": [], "denials": [],
           "brain_calls": 0, "file_reads": 0}
    try:
        d, tools, denials = load_run(raw)
        rec.update(measure(d, tools, denials))
        answer = rec.pop("_full")  # grade the whole answer; the record keeps a prefix
        rec["correct"] = re.search(expected, answer, re.I | re.S) is not None
        # A trap is the shape of a made-up or stale specific; falling in it is a
        # miss whatever else the answer says.
        if trap:
            rec["trap"] = re.search(trap, answer, re.I | re.S) is not None
            rec["correct"] = rec["correct"] and not rec["trap"]
    except Exception as e:  # a run that produced no JSON is a failed run, recorded as such
        rec["error"] = f"{type(e).__name__}: {e}"
    rec.pop("_full", None)
    print(json.dumps(rec, ensure_ascii=False))

if __name__ == "__main__":
    main()
