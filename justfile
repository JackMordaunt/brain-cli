# Recipes run through `sh -cu`: just ships no shell, so on Windows this needs
# Git Bash on PATH — the same assumption the tooling itself makes.

default:
    @just --list

# Syntax-check every script in the repo.
build:
    @for f in bin/brain bin/hooks/* bin/shims/*; do bash -n "$f" && echo "ok $f"; done

# Nothing is compiled; release is the same check.
release: build

# Run against the fixture vault, never the caller's own: the suite must pass on
# a machine that has no notes at all.
test: build
    #!/usr/bin/env bash
    set -euo pipefail
    export BRAIN_STATE="$(mktemp -d)"
    trap 'rm -rf "$BRAIN_STATE"' EXIT
    # A copy, so a test can edit the vault without dirtying the fixture.
    cp -r testdata/vault "$BRAIN_STATE/vault"
    export BRAIN_VAULT="$BRAIN_STATE/vault"
    bin/brain sync
    bin/brain lint
    # Captured, never piped into grep -q: that closes the pipe early, and under
    # pipefail the writer's SIGPIPE fails the whole pipeline.
    out=$(bin/brain find sqlite);  case "$out" in *'**sqlite**'*) echo "ok find bullet"   ;; *) echo "FAIL find bullet";   exit 1 ;; esac
    out=$(bin/brain find handoff); case "$out" in *'documents'*)  echo "ok find document" ;; *) echo "FAIL find document"; exit 1 ;; esac
    bin/brain find zzzznope >/dev/null 2>&1 && { echo "FAIL: miss should exit non-zero"; exit 1; } || echo "ok miss"
    bin/brain doctor  >/dev/null && echo "ok doctor"
    bin/brain log     >/dev/null && echo "ok log"
    bin/brain locate --tool >/dev/null && echo "ok locate --tool"
    test "$(bin/brain locate)" = "$BRAIN_VAULT" && echo "ok locate"

    # The log counts entries, not output lines, and records who asked.
    out=$(BRAIN_CALLER=fixture-agent BRAIN_SESSION=sess-a bin/brain find sqlite)
    entries=$(grep -c '\.md:[0-9]*' <<< "$out")
    logged=$(sqlite3 "$BRAIN_STATE/brain.db" "select hits || ' ' || caller || ' ' || session from queries order by id desc limit 1")
    test "$logged" = "$entries fixture-agent sess-a" && echo "ok log counts entries and caller ($logged)" || { echo "FAIL log row: '$logged' vs $entries entries"; exit 1; }
    # The log is evidence and must survive a rebuild. On Windows the carry-over
    # once attached a path sqlite3.exe could not open, and every sync erased it.
    nq=$(sqlite3 "$BRAIN_STATE/brain.db" "select count(*) from queries")
    bin/brain sync >/dev/null
    test "$(sqlite3 "$BRAIN_STATE/brain.db" "select count(*) from queries")" = "$nq" && echo "ok log survives sync ($nq)" || { echo "FAIL sync dropped the query log"; exit 1; }
    # A miss that a later edit answers leaves the backlog on its own.
    printf -- '- **zzzznope** (aliases: nope) — now written down — fixture — 2026-01-02\n' >> "$BRAIN_VAULT/AI/MEMORY.md"
    out=$(bin/brain log)
    case "$out" in *'missed then answered'*zzzznope*) echo "ok log clears an answered miss" ;; *) echo "FAIL log should set the answered miss aside"; exit 1 ;; esac
    grep -q '^│ zzzznope' <<< "$out" && { echo "FAIL answered miss still in the backlog table"; exit 1; } || true
    # Promotion reads the query log: three queries on the same bullet flag it.
    bin/brain find sqlite >/dev/null; bin/brain find sqlite >/dev/null
    out=$(bin/brain doctor || true)
    case "$out" in *'promote candidates'*'sqlite'*) echo "ok doctor promotes by query frequency" ;; *) echo "FAIL doctor promote"; exit 1 ;; esac

    # recall runs against a fixture source, never anyone's real transcripts.
    export BRAIN_ADAPTERS="$PWD/testdata/adapters"
    export FIXTURE_TRANSCRIPTS="$PWD/testdata/transcripts"
    export XDG_CONFIG_HOME="$BRAIN_STATE/config"
    bin/brain recall playhead >/dev/null 2>&1 && { echo "FAIL: recall with no source should exit non-zero"; exit 1; } || echo "ok recall needs a source"
    bin/brain recall --enable fixture >/dev/null
    bin/brain recall --sync >/dev/null
    out=$(bin/brain recall playhead)
    case "$out" in *'[playhead]'*) echo "ok recall snippet" ;; *) echo "FAIL recall snippet"; exit 1 ;; esac
    case "$out" in *'The playhead session'*) echo "ok recall title" ;; *) echo "FAIL recall title"; exit 1 ;; esac
    case "$out" in *makepkg*) echo "FAIL recall leaked an unrelated turn"; exit 1 ;; *) echo "ok recall scoped" ;; esac
    out=$(bin/brain recall playhead --exclude sess-one 2>&1 || true)
    case "$out" in *'no hits'*) echo "ok recall --exclude" ;; *) echo "FAIL recall --exclude"; exit 1 ;; esac
    out=$(bin/brain recall --full f1)
    case "$out" in *'frame you clicked'*) echo "ok recall --full" ;; *) echo "FAIL recall --full"; exit 1 ;; esac
    out=$(bin/brain recall playhead --json)
    printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[0]["title"]' && echo "ok recall --json"
    out=$(bin/brain recall playhead --sessions)
    case "$out" in *'sess-one'*) echo "ok recall --sessions" ;; *) echo "FAIL recall --sessions"; exit 1 ;; esac
    test "$(bin/brain recall playhead --sessions | wc -l)" = 1 || { echo "FAIL --sessions should group"; exit 1; }
    bin/brain recall playh --sessions >/dev/null 2>&1 && { echo "FAIL a half word should not match"; exit 1; } || echo "ok exact needs the whole word"
    out=$(bin/brain recall playh --sessions --prefix)
    case "$out" in *'sess-one'*) echo "ok recall --prefix" ;; *) echo "FAIL recall --prefix"; exit 1 ;; esac

    # The hooks must find the CLI as their own sibling, not inside the repo
    # being committed: when the tool lived in the vault, `$root/bin/brain`
    # worked by accident, and splitting them turned the gate into a silent pass.
    hookrepo="$BRAIN_STATE/hookrepo"
    mkdir -p "$hookrepo" && cp -r testdata/vault/AI "$hookrepo/"
    git -C "$hookrepo" init -q
    git -C "$hookrepo" config user.email t@example.com
    git -C "$hookrepo" config user.name test
    git -C "$hookrepo" config core.hooksPath "$PWD/bin/hooks"
    printf -- '- **undated** (aliases: x) — a bullet with no trailing date — fixture\n' >> "$hookrepo/AI/MEMORY.md"
    git -C "$hookrepo" add -A
    if git -C "$hookrepo" commit -q -m "probe" 2>/dev/null; then
      echo "FAIL: pre-commit let an undated bullet through"; exit 1
    else
      echo "ok pre-commit gate fires from outside the repo"
    fi

    # Re-syncing the same fixture must not double-count: ids are the key.
    before=$(bin/brain recall --sync | tail -1)
    after=$(bin/brain recall --sync | tail -1)
    test "$before" = "$after" && echo "ok recall idempotent ($after)"

# Put the CLI on PATH and bind this machine to a vault.
install VAULT:
    bin/brain install {{VAULT}}

# The index is disposable; the markdown is canonical.
clean:
    rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/brain"
