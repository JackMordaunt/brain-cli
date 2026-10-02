#!/usr/bin/env python3
"""Behaviour experiments: does memory change what the agent does, and does
the agent feed memory back. Two kinds, one isolated `claude -p` per run:

  behave.py tasks   tasks.tsv    --out DIR   a task whose right action a bullet changes
                                            (covered) or cannot (uncovered); the check
                                            reads the answer and every file written
  behave.py capture capture.tsv --out DIR   phase 1 states a new fact and asks for a small
                                            task; phase 2 is a fresh session in a fresh
                                            directory on the same vault, asking for it

Conditions (--conditions, default all four): vanilla, plain, brain, brain-auto.
Each run gets its own home (credentials; the brain hooks for brain-auto),
vault copy, state and working directory, so runs never see each other.
Records go to DIR/runs.jsonl in the lookup runner's schema plus
experiment, covered, phase, captured, captured_local, lint_ok, files.
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from record import load_run, measure
from vaults import copy as copy_vault

TOOLS = ["Read", "Grep", "Glob", "Write", "Edit", "Bash(brain:*)", "Bash(grep:*)", "Bash(rg:*)", "Bash(cat:*)",
         "Bash(ls:*)", "Bash(find:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(sed:*)", "Bash(wc:*)", "Bash(python3:*)",
         "Bash(bash:*)", "Bash(sh:*)", "Bash(chmod:*)", "Bash(mkdir:*)", "Bash(echo:*)", "Bash(printf:*)", "Bash(test:*)"]

VANILLA = "This is a scratch project directory with no notes of its own. Do the task; write files here.\n"
PLAIN = ("Your notes live at {vault}. AI/MEMORY.md, AI/LEARNINGS.md and AI/TUNINGS.md hold one fact per line in the shape "
         "`- **handle** (aliases: ...) — fact — source — date`; the other folders hold longer notes. Search the notes "
         "before you act, and prefer what they say to what you assume. When work settles a durable fact, append a bullet "
         "in that shape to AI/INBOX.md in the notes.\n")
# What `brain install` writes for Claude Code, minus the @-include of a file
# this home does not have: brain-auto is this block plus the hooks, the real
# install. brain is what `brain export` opens a hook-less agent's file with
# (export.odin ASK_HEAD): told to ask, with no hooks to ask for it.
BLOCK = ("The Brain is this machine's shared agent memory. `brain locate` prints its path,\n"
         "`brain find <handle>` searches it, and `brain recall <terms>` searches what was\n"
         "said in past agent conversations. Do not hard-code the path. A session opens\n"
         "with `brain pack`, the vault's bullets about this repository. When work settles\n"
         "a durable fact, `brain propose '- **handle** (aliases: ...) — fact'` records it\n"
         "for a person to review; never edit the vault's core files directly.\n")
ASK = ("Memory for this repository, from the Brain vault (`brain locate`). Before acting on a task, run "
       "`brain find <key terms>` (a tool, an error, a file) and act on what comes back. When work settles a "
       "durable fact, `brain propose '- **handle** (aliases: ...) — fact'` records it for a person to review.\n")
CLAUDE_MD = {"vanilla": VANILLA, "plain": PLAIN, "brain": ASK, "brain-auto": BLOCK}

def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            if line.strip():
                rows.append(dict(zip(head, line.rstrip("\n").split("\t"))))
    return rows

def vault_text(vault):
    """Every line of every markdown file, as a set, to diff before and after."""
    lines = set()
    for root, _, files in os.walk(vault):
        for f in files:
            if f.endswith(".md"):
                p = os.path.join(root, f)
                try:
                    for l in open(p, encoding="utf-8", errors="replace"):
                        lines.add((os.path.relpath(p, vault), l.rstrip("\n")))
                except OSError:
                    pass  # a file the agent is mid-write on; the diff is best effort
    return lines

def cwd_files(cwd):
    out = {}
    for root, dirs, files in os.walk(cwd):
        dirs[:] = [x for x in dirs if x != ".git"]
        for f in files:
            if f == "CLAUDE.md":
                continue
            p = os.path.join(root, f)
            try:
                out[os.path.relpath(p, cwd)] = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                pass  # unreadable output (a socket, a vanished temp file) is not a written file
    return out

class Lab:
    def __init__(self, a):
        self.a = a
        self.work = tempfile.mkdtemp(prefix="proof-behave-")
        self.brain = os.path.abspath(a.brain)
        self.claude = a.claude or shutil.which("claude")
        if not self.claude:
            sys.exit("no claude on PATH; CLAUDE=<path>")
        self.vault_src = a.vault or subprocess.check_output(["brain", "locate"], text=True).strip()
        os.makedirs(os.path.join(self.work, "bin"))
        os.symlink(self.brain, os.path.join(self.work, "bin", "brain"))
        os.makedirs(a.out + "/raw", exist_ok=True)
        self.cred = os.path.expanduser("~/.claude/.credentials.json")

    def run_dir(self, name, cond):
        d = os.path.join(self.work, name)
        home = os.path.join(d, "home")
        os.makedirs(os.path.join(home, ".claude"))
        shutil.copy(self.cred, os.path.join(home, ".claude"))
        vault = os.path.join(d, "vault")
        copy_vault(self.vault_src, vault)
        state = os.path.join(d, "state")
        os.makedirs(state)
        env = self.env(cond, home, vault, state)
        subprocess.run([self.brain, "reindex"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if cond == "brain-auto":
            # The hooks name `brain` bare. When they named it by absolute path
            # (2026-10-02 smoke), the agent copied that spelling into its own
            # calls and the Bash(brain:*) allow rule refused them.
            e = dict(env, BRAIN_EXE="brain")
            subprocess.run([self.brain, "hooks", "on"], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return d, env

    def env(self, cond, home, vault, state):
        path = "/usr/bin:/bin"
        if cond in ("brain", "brain-auto"):
            path = os.path.join(self.work, "bin") + ":" + path
        return {"HOME": home, "PATH": path, "TERM": "dumb", "LANG": "C.UTF-8", "BRAIN_VAULT": vault,
                "BRAIN_STATE": state, "BRAIN_NO_UPDATE": "1"}

    def scratch(self, d, cond, n, repo=""):
        # A task may say which repository it happens in; the directory takes
        # that name (and a .git) so `brain pack` serves that project's bullets,
        # as it would in the real repository. Otherwise a scratch name.
        cwd = os.path.join(d, repo or f"cwd{n}")
        os.makedirs(cwd)
        if repo:
            os.makedirs(os.path.join(cwd, ".git"))
        with open(os.path.join(cwd, "CLAUDE.md"), "w") as f:
            f.write(CLAUDE_MD[cond].format(vault=os.path.join(d, "vault")))
        return cwd

    def session(self, cwd, env, prompt, system, raw):
        # Sessions persist (in the run's own home): the Stop hook reads the
        # transcript from disk, so without one settle can never fire.
        cmd = [self.claude, "-p", prompt, "--output-format", "stream-json", "--verbose", "--model", self.a.model,
               "--max-turns", str(self.a.max_turns), "--max-budget-usd", "1",
               "--append-system-prompt", system]
        # plain reads and writes the vault with Claude Code's own tools. In the
        # 2026-10-02 smoke one session refused the vault path as outside the
        # working directory, so the vault is added as one.
        if "notes live at" in open(os.path.join(cwd, "CLAUDE.md")).read():
            cmd += ["--add-dir", env["BRAIN_VAULT"]]
        cmd += ["--allowedTools", *TOOLS]
        t0 = time.time()
        with open(raw, "w") as out, open(raw + ".err", "w") as err:
            subprocess.run(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=900)
        try:
            d, tools, denials = load_run(raw)
        except Exception as e:
            d, tools, denials = {"is_error": True, "result": f"{type(e).__name__}: {e}", "duration_ms": (time.time() - t0) * 1000}, [], []
        return measure(d, tools, denials)

    def keep(self, cwd, name):
        """Copy what the agent wrote into the output, so a check can be rerun."""
        dst = os.path.join(self.a.out, "files", name)
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(cwd, dst, ignore=shutil.ignore_patterns("CLAUDE.md", ".git"))

    def lint_ok(self, env, vault, files):
        if not files:
            return None
        r = subprocess.run([self.brain, "lint", "--json", *[os.path.join(vault, f) for f in files]], env=env,
                           capture_output=True, text=True)
        try:
            return bool(json.loads(r.stdout).get("ok"))
        except Exception:
            return r.returncode == 0

# --- checks -----------------------------------------------------------------

CLASS = "chrome-web.whatsapp.com__-Default"

def check_hypr_class(text, cwd):
    for m in re.finditer(r"class\s*[:=]\s*['\"]?([^,'\"\n]+)", text):
        pat = m.group(1).strip().rstrip("} ")
        try:
            if re.fullmatch(pat, CLASS):
                return True
        except re.error:
            pass  # an invalid regex matches nothing, which is the agent's miss
    return False

def check_mpv_name(text, cwd):
    if re.search(r"load-scripts[= ]no", text):
        return True
    vals = re.findall(r"audio-client-name[= ](?:\"([^\"]*)\"|'([^']*)'|(\S+))", text)
    if not vals:
        return False
    return not any(" " in (a or b or c) for a, b, c in vals)

PY = {"hypr_class": check_hypr_class, "mpv_name": check_mpv_name}

def check(spec, answer, files, cwd):
    text = answer + "\n" + "\n".join(f"### {k}\n{v}" for k, v in files.items())
    kind, _, arg = spec.partition(":")
    if kind == "re":
        return re.search(arg, text, re.I | re.S) is not None
    if kind == "py":
        return PY[arg](text, cwd)
    if kind == "run":
        cmd, _, want = arg.partition("||")
        try:
            r = subprocess.run(["bash", "-c", cmd], cwd=cwd, capture_output=True, text=True, timeout=20,
                               env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        except subprocess.TimeoutExpired:
            return False
        return r.returncode == 0 and re.search(want, r.stdout, re.S) is not None
    raise ValueError(spec)

# --- experiments -------------------------------------------------------------

def one_task(lab, row, cond, rep):
    name = f"{lab.a.model}-{cond}-{row['id']}-{rep}"
    d, env = lab.run_dir(name, cond)
    cwd = lab.scratch(d, cond, 1, "" if lab.a.no_repo else row.get("repo", ""))
    rec = lab.session(cwd, env, row["prompt"], "Write files into the current directory. Keep the final reply under five sentences.",
                      os.path.join(lab.a.out, "raw", name + ".json"))
    files = cwd_files(cwd)
    lab.keep(cwd, name)
    full = rec.pop("_full", rec["answer"])
    rec.update(experiment="tasks", model=lab.a.model, condition=cond, question=row["id"], repeat=rep, kind="task",
               covered=row["covered"] == "yes", repo=("" if lab.a.no_repo else row.get("repo", "")), phase=1, files=sorted(files), correct=False)
    try:
        rec["correct"] = check(row["check"], full, files, cwd)
    except Exception as e:
        rec["error"] = rec["error"] or f"check: {e}"
    shutil.rmtree(d, ignore_errors=True)
    return [rec]

def one_capture(lab, row, cond, rep):
    name = f"{lab.a.model}-{cond}-{row['id']}-{rep}"
    d, env = lab.run_dir(name, cond)
    vault = os.path.join(d, "vault")
    before = vault_text(vault)
    cwd = lab.scratch(d, cond, 1)
    rec = lab.session(cwd, env, row["fact"] + " " + row["task"],
                      "Write files into the current directory. Keep the final reply under five sentences.",
                      os.path.join(lab.a.out, "raw", name + "-p1.json"))
    rec.pop("_full", None)
    settle_dir = os.path.join(d, "state", "settle")
    settle_asked = os.path.isdir(settle_dir) and bool(os.listdir(settle_dir))  # settle stamped the session: it asked
    gained = [(f, l) for f, l in vault_text(vault) - before]
    hits = [(f, l) for f, l in gained if re.search(row["expected"], l, re.I)]
    files = cwd_files(cwd)
    lab.keep(cwd, name + "-p1")
    local = [f for f, t in files.items() if re.search(row["expected"], t, re.I)]
    if hits:
        with open(os.path.join(lab.a.out, "files", name + "-p1", "GAINED.md"), "w") as f:
            f.write("".join(f"{fn}: {l}\n" for fn, l in gained))
    rec.update(experiment="capture", model=lab.a.model, condition=cond, question=row["id"], repeat=rep, kind="capture",
               phase=1, correct=bool(hits), captured=bool(hits), captured_in=sorted({f for f, _ in hits}), settle_asked=settle_asked,
               gained_lines=len(gained), captured_local=sorted(local), files=sorted(files),
               lint_ok=lab.lint_ok(env, vault, sorted({f for f, _ in hits})))
    # Phase 2: a new session, a new directory, the same memory.
    cwd2 = lab.scratch(d, cond, 2)
    rec2 = lab.session(cwd2, env, row["question"], "Answer in at most three sentences.",
                       os.path.join(lab.a.out, "raw", name + "-p2.json"))
    full2 = rec2.pop("_full", rec2["answer"])
    rec2.update(experiment="capture", model=lab.a.model, condition=cond, question=row["id"], repeat=rep, kind="roundtrip",
                phase=2, correct=re.search(row["expected"], full2, re.I | re.S) is not None,
                captured=rec["captured"])
    shutil.rmtree(d, ignore_errors=True)
    return [rec, rec2]

def regrade(a, rows):
    """Recompute every grade in --out from raw/ and files/, without the agents.
    A check or a question's regex can change after the run."""
    by = {r["id"]: r for r in rows}
    path = os.path.join(a.out, "runs.jsonl")
    recs = [json.loads(l) for l in open(path) if l.strip()]
    for r in recs:
        row = by.get(r["question"])
        if not row:
            continue
        name = f"{r['model']}-{r['condition']}-{r['question']}-{r['repeat']}"
        suffix = "" if a.kind == "tasks" else f"-p{r.get('phase', 1)}"
        raw = os.path.join(a.out, "raw", name + suffix + ".json")
        try:
            d, tools, denials = load_run(raw)
        except Exception as e:
            r["error"] = f"{type(e).__name__}: {e}"
            continue
        m = measure(d, tools, denials)
        full = m.pop("_full")
        r.update(m)
        if a.kind == "tasks":
            fdir = os.path.join(a.out, "files", name)
            files = cwd_files(fdir) if os.path.isdir(fdir) else {}
            try:
                r["correct"] = check(row["check"], full, files, fdir)
            except Exception as e:
                r["error"] = r["error"] or f"check: {e}"
        elif r.get("phase") == 2:
            r["correct"] = re.search(row["expected"], full, re.I | re.S) is not None
        else:
            r["correct"] = r.get("captured", False)
    with open(path, "w") as f:
        for r in recs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"regraded {len(recs)} records -> {path}")

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("kind", choices=["tasks", "capture"])
    p.add_argument("--regrade", action="store_true", help="regrade --out from raw/ and files/ instead of running")
    p.add_argument("--no-repo", action="store_true", help="ignore the tasks' repo column: every task runs in a scratch directory")
    p.add_argument("spec")
    p.add_argument("--out", required=True)
    p.add_argument("--conditions", default="vanilla plain brain brain-auto")
    p.add_argument("--model", default=os.environ.get("MODEL", "sonnet"))
    p.add_argument("--repeats", type=int, default=int(os.environ.get("REPEATS", "1")))
    p.add_argument("--jobs", type=int, default=int(os.environ.get("JOBS", "2")))
    p.add_argument("--ids", default="", help="comma-separated row ids to run; default all")
    p.add_argument("--max-turns", type=int, default=16)
    p.add_argument("--vault", default=os.environ.get("VAULT"))
    p.add_argument("--brain", default=os.environ.get("BRAIN", os.path.join(ROOT, "build", "release", "brain")))
    p.add_argument("--claude", default=os.environ.get("CLAUDE"))
    a = p.parse_args()
    rows = read_tsv(a.spec)
    if a.ids:
        want = set(a.ids.split(","))
        rows = [r for r in rows if r["id"] in want]
    if a.regrade:
        regrade(a, rows)
        return
    lab = Lab(a)
    runner = one_task if a.kind == "tasks" else one_capture
    jobs = [(row, cond, rep) for rep in range(1, a.repeats + 1) for row in rows for cond in a.conditions.split()]
    log = open(os.path.join(a.out, "runs.jsonl"), "a")
    def go(job):
        row, cond, rep = job
        try:
            recs = runner(lab, row, cond, rep)
        except Exception as e:
            recs = [{"experiment": a.kind, "model": a.model, "condition": cond, "question": row["id"], "repeat": rep,
                     "kind": a.kind, "correct": False, "tokens": 0, "turns": 0, "cost": 0.0, "seconds": 0.0,
                     "answer": "", "error": f"{type(e).__name__}: {e}"}]
        for r in recs:
            log.write(json.dumps(r, ensure_ascii=False) + "\n"); log.flush()
            extra = ""
            if r.get("kind") == "capture":
                extra = f" captured={r['captured']} lint={r.get('lint_ok')} settle_asked={r.get('settle_asked')} local={bool(r.get('captured_local'))}"
            print(f"{a.model} {cond} {row['id']} r{rep} p{r.get('phase', 1)}: {'ok ' if r['correct'] else 'MISS'} "
                  f"{r['tokens']} tokens, {r['turns']} turns, ${r['cost']:.3f}{extra}", flush=True)
    try:
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            list(ex.map(go, jobs))
    finally:
        log.close()
        shutil.rmtree(lab.work, ignore_errors=True)
    print(f"wrote {os.path.join(a.out, 'runs.jsonl')}")

if __name__ == "__main__":
    main()
