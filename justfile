# Recipes run through `sh -cu`: just ships no shell, so on Windows this needs
# Git Bash on PATH. The tool itself is one static binary and needs nothing.
#
#   just build     debug binary with the debug allocator and ASan -> build/debug
#   just release   optimised binary                                -> build/release
#   just test      the package's tests against the fixture vault
#   just check     type-check for linux, darwin and windows, debug and release
#   just install   bind this machine to a vault
#   just clean     remove build/ and the index

odin  := env("ODIN", "odin")
# The jm collection: https://github.com/jackmordaunt/jm, checked out beside
# this repository by default. JM overrides.
jm    := env("JM", replace(home_directory() / "Source" / "jm", "\\", "/"))
root  := replace(justfile_directory(), "\\", "/")
flags := "-vet -strict-style -collection:jm=" + jm + " -define:BRAIN_TOOL=" + root
# `just build SAN=` drops the sanitizer when a library gets in its way.
san   := env("SAN", "-sanitize:address")
exe   := if os() == "windows" { ".exe" } else { "" }
targets := "linux_amd64 darwin_arm64 windows_amd64"

default:
    @just --list --unsorted

# Debug binary -> build/debug/brain
build:
    mkdir -p build/debug
    {{odin}} build . -debug {{san}} {{flags}} -out:build/debug/brain{{exe}}

# Optimised binary -> build/release/brain
release:
    mkdir -p build/release
    {{odin}} build . -o:speed {{flags}} -out:build/release/brain{{exe}}

# Type-check every target, with and without -debug.
check:
    for t in {{targets}}; do \
      {{odin}} check . {{flags}} -target:$t || exit 1; \
      {{odin}} check . {{flags}} -debug -target:$t || exit 1; \
    done

# The package's tests, which run the built binary through the hooks and an
# install into a throwaway home, then a syntax check of the hooks and shims.
# One thread: tests that spawn git deadlock in parallel on Windows, where a
# child inherits another child's pipe and its parent never reads EOF.
test: build test-installer
    mkdir -p build/test
    {{odin}} test brain {{san}} {{flags}} -define:ODIN_TEST_THREADS=1 -out:build/test/brain{{exe}}
    @for f in bin/hooks/* bin/shims/*; do bash -n "$f" && echo "ok $f"; done

# install.cmd against a fake release on disk: the release binary under the
# name CI would publish, a sha256sums.txt beside it, served over file://.
# The sh half runs everywhere; on Windows the cmd half runs too, and both
# must refuse an asset whose checksum no longer matches.
test-installer: release
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -s)" in Linux*) os=linux;; Darwin*) os=darwin;; *) os=windows;; esac
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; *) arch=arm64;; esac
    asset="brain-$os-$arch{{exe}}"
    rel="$(mktemp -d)/release"; bin="$(mktemp -d)/bin"
    trap 'rm -rf "$(dirname "$rel")" "$(dirname "$bin")"' EXIT
    mkdir -p "$rel" && cp "build/release/brain{{exe}}" "$rel/$asset"
    (cd "$rel" && { command -v sha256sum >/dev/null && sha256sum brain-* || shasum -a 256 brain-*; } > sha256sums.txt)
    p=$(cygpath -m "$rel" 2>/dev/null || printf '%s' "$rel")
    export BRAIN_RELEASE_BASE="file:///${p#/}"
    BRAIN_BINDIR="$bin/sh" sh install.cmd >/dev/null
    test "$("$bin/sh/brain{{exe}}" locate --tool)" = "$(build/release/brain{{exe}} locate --tool)" && echo "ok install.cmd (sh)"
    if command -v cygpath >/dev/null 2>&1; then
      MSYS_NO_PATHCONV=1 cmd /c "set BRAIN_BINDIR=$(cygpath -w "$bin")\cmd&& $(cygpath -w "$PWD")\install.cmd" >/dev/null
      test "$("$bin/cmd/brain.exe" locate --tool)" = "$(build/release/brain.exe locate --tool)" && echo "ok install.cmd (cmd)"
    fi
    printf x >> "$rel/$asset"
    if BRAIN_BINDIR="$bin/t" sh install.cmd >/dev/null 2>&1; then echo "FAIL install.cmd accepted a bad checksum"; exit 1; fi
    echo "ok install.cmd refuses a bad checksum (sh)"
    if command -v cygpath >/dev/null 2>&1; then
      if MSYS_NO_PATHCONV=1 cmd /c "set BRAIN_BINDIR=$(cygpath -w "$bin")\t2&& $(cygpath -w "$PWD")\install.cmd" >/dev/null 2>&1; then echo "FAIL install.cmd (cmd) accepted a bad checksum"; exit 1; fi
      echo "ok install.cmd refuses a bad checksum (cmd)"
    fi

# Put the CLI on PATH and bind this machine to a vault.
install VAULT: release
    build/release/brain{{exe}} install {{VAULT}}

# The index is disposable; the markdown is canonical.
clean:
    rm -rf build "${XDG_STATE_HOME:-$HOME/.local/state}/brain"
