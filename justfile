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

# Put the CLI on PATH and bind this machine to a vault.
install VAULT:
    bin/brain install {{VAULT}}

# The index is disposable; the markdown is canonical.
clean:
    rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/brain"
