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
    export BRAIN_VAULT="$PWD/testdata/vault"
    export BRAIN_STATE="$(mktemp -d)"
    trap 'rm -rf "$BRAIN_STATE"' EXIT
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
