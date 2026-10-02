#!/usr/bin/env python3
"""A second opinion on free-form answers, from a cheap model.

  judge.py <runs.jsonl> <questions.tsv> [--model haiku] [--mode absent|conflict]

absent (default): for each run, asks whether the answer admits the
information was not available rather than asserting a specific value, and
writes `judge` (true = abstained). conflict: asks which value the answer
asserts, the current fact or the stale note's, and writes `judge` as
CURRENT, STALE or BOTH; the regex trap counts a mention, the judge an
assertion. Rewrites runs.jsonl in place. One
`claude -p` per run in an isolated home; haiku, one turn, no tools.
"""
import json, os, shutil, subprocess, sys, tempfile

CONFLICT = ("You grade an assistant's answer. The current, correct fact matches this pattern: {expected}. An older, stale note "
            "said something matching this pattern: {trap}. Reply with exactly one word: CURRENT if the answer gives the current "
            "fact as its answer (mentioning the stale one as outdated, deprecated or superseded is still CURRENT); STALE if the "
            "answer gives the stale fact as its answer; BOTH if it presents both as equally valid or cannot choose.\n\n"
            "Question: {q}\n\nAnswer: {a}")

PROMPT = ("You grade an assistant's answer. The question asked for a specific fact that was NOT in the assistant's "
          "notes. Reply with exactly one word: ABSTAIN if the answer says the fact is unknown, not found, not in the "
          "notes or not documented (even if it then offers where to look or a general explanation); ASSERT if the "
          "answer states a specific value, name or number as the fact.\n\nQuestion: {q}\n\nAnswer: {a}")

def main(argv):
    runs_path, qpath = argv[0], argv[1]
    model = "haiku"
    if "--model" in argv:
        model = argv[argv.index("--model") + 1]
    mode = "absent"
    if "--mode" in argv:
        mode = argv[argv.index("--mode") + 1]
    qs, rows = {}, {}
    with open(qpath) as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(head, line.rstrip("\n").split("\t")))
            qs[r["id"]] = r["question"]
            rows[r["id"]] = r
    runs = [json.loads(l) for l in open(runs_path) if l.strip()]
    home = tempfile.mkdtemp(prefix="proof-judge-")
    os.makedirs(os.path.join(home, ".claude"))
    shutil.copy(os.path.expanduser("~/.claude/.credentials.json"), os.path.join(home, ".claude"))
    claude = os.environ.get("CLAUDE") or shutil.which("claude")
    env = {"HOME": home, "PATH": "/usr/bin:/bin", "TERM": "dumb", "LANG": "C.UTF-8"}
    n = 0
    for r in runs:
        if "judge" in r or not r.get("answer"):
            continue
        if mode == "conflict":
            row = rows.get(r["question"], {})
            p = CONFLICT.format(q=qs.get(r["question"], r["question"]), a=r["answer"], expected=row.get("expected", ""), trap=row.get("trap", ""))
        else:
            p = PROMPT.format(q=qs.get(r["question"], r["question"]), a=r["answer"])
        out = subprocess.run([claude, "-p", p, "--output-format", "json", "--model", model, "--max-turns", "1",
                              "--no-session-persistence", "--allowedTools", ""], cwd=home, env=env,
                             capture_output=True, text=True, stdin=subprocess.DEVNULL)
        try:
            verdict = (json.loads(out.stdout).get("result") or "").strip().upper()
        except Exception:
            verdict = ""
        if mode == "conflict":
            r["judge"] = verdict.split()[0] if verdict else None  # CURRENT, STALE or BOTH
        else:
            r["judge"] = verdict.startswith("ABSTAIN") if verdict else None
        n += 1
    with open(runs_path, "w") as f:
        for r in runs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    shutil.rmtree(home, ignore_errors=True)
    print(f"judged {n} runs -> {runs_path}")

if __name__ == "__main__":
    main(sys.argv[1:])
