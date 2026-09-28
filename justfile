# Recipes run through `sh -cu`: just ships no shell, so on Windows this needs
# Git Bash on PATH. The tool itself is one static binary and needs nothing.
#
#   just deps      fetch the jm submodule and build its SQLite archive
#   just build     debug binary with the debug allocator and ASan -> build/debug
#   just release   optimised binary                                -> build/release
#   just test      the package's tests against the fixture vault
#   just check     type-check for linux, darwin and windows, debug and release
#   just install   bind this machine to a vault
#   just clean     remove build/ and the index

odin  := env("ODIN", "odin")
root  := replace(justfile_directory(), "\\", "/")
# The jm collection: https://mordaunt.dev/code/jm, pinned as the jm
# submodule. JM=<path> builds against another checkout instead.
jm    := env("JM", root / "jm")
flags := "-vet -strict-style -collection:jm=" + jm + " -define:BRAIN_TOOL=" + root
# `just build SAN=` drops the sanitizer when a library gets in its way.
san   := env("SAN", "-sanitize:address")
exe   := if os() == "windows" { ".exe" } else { "" }
targets := "linux_amd64 darwin_arm64 windows_amd64"

default:
    @just --list --unsorted

# The jm submodule, when JM does not name another checkout, and its SQLite
# archive, which jm:sqlite3 links.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    if ! ls "{{jm}}"/sqlite3/lib/sqlite3.* >/dev/null 2>&1; then (cd "{{jm}}" && just sqlite); fi

# Debug binary -> build/debug/brain
build: deps
    mkdir -p build/debug
    {{odin}} build . -debug {{san}} {{flags}} -out:build/debug/brain{{exe}}

# Optimised binary -> build/release/brain
release: deps
    mkdir -p build/release
    {{odin}} build . -o:speed {{flags}} -out:build/release/brain{{exe}}

# Type-check every target, with and without -debug.
check: deps
    for t in {{targets}}; do \
      {{odin}} check . {{flags}} -target:$t || exit 1; \
      {{odin}} check . {{flags}} -debug -target:$t || exit 1; \
    done

# The package's tests, which run the built binary through the hooks and an
# install into a throwaway home, then a syntax check of the hooks.
# One thread: tests that spawn git deadlock in parallel on Windows, where a
# child inherits another child's pipe and its parent never reads EOF.
test: build test-installer
    mkdir -p build/test
    {{odin}} test brain {{san}} {{flags}} -define:ODIN_TEST_THREADS=1 -out:build/test/brain{{exe}}
    @for f in bin/hooks/*; do bash -n "$f" && echo "ok $f"; done

# The installers against a fake release on disk: the release binary under
# the names CI would publish, a sha256sums.txt beside them, served over
# file://. Each ends in `brain install`, so all of it runs in a throwaway
# home, where the canonical vault gets created. install.sh runs everywhere;
# install.ps1 installs on Windows and, wherever a PowerShell is on PATH,
# must refuse an asset whose checksum no longer matches. Off Windows its
# .exe cannot run, and PowerShell would hand it to xdg-open.
test-installer: release
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -s)" in Linux*) os=linux;; Darwin*) os=darwin;; *) os=windows;; esac
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; *) arch=arm64;; esac
    # The installers run before any binary exists, so they repeat the
    # release base the binary owns; all three must agree.
    base=$(sed -n 's/^RELEASE_BASE :: "\(.*\)"$/\1/p' brain/version.odin)
    for f in install.sh install.ps1; do grep -qF "$base" "$f" || { echo "FAIL $f does not name $base"; exit 1; }; done
    echo "ok the installers name the release base"
    rel="$(mktemp -d)/release"; bin="$(mktemp -d)/bin"; home="$(mktemp -d)"
    trap 'rm -rf "$(dirname "$rel")" "$(dirname "$bin")" "$home"' EXIT
    export HOME="$home" USERPROFILE="$(cygpath -w "$home" 2>/dev/null || printf '%s' "$home")"
    export XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.state"
    unset BRAIN_VAULT BRAIN_STATE BRAIN_TOOL GOBIN GOPATH
    mkdir -p "$rel"
    cp "build/release/brain{{exe}}" "$rel/brain-$os-$arch{{exe}}"
    cp "build/release/brain{{exe}}" "$rel/brain-windows-amd64.exe"
    (cd "$rel" && { command -v sha256sum >/dev/null && sha256sum brain-* || shasum -a 256 brain-*; } > sha256sums.txt)
    p=$(cygpath -m "$rel" 2>/dev/null || printf '%s' "$rel")
    export BRAIN_RELEASE_BASE="file:///${p#/}"
    w() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
    ps=$(command -v pwsh || command -v powershell || true)
    ps1() { BRAIN_BINDIR="$(w "$1")" "$ps" -NoProfile -ExecutionPolicy Bypass -File "$(w "$PWD/install.ps1")"; }

    BRAIN_BINDIR="$bin/sh" sh install.sh >/dev/null
    test "$("$bin/sh/brain{{exe}}" locate --tool)" = "$(build/release/brain{{exe}} locate --tool)"
    test "$("$bin/sh/brain{{exe}}" locate)" = "$home/Documents/Brain" && echo "ok install.sh"
    if [ -n "$ps" ] && [ "$os" = windows ]; then
      ps1 "$bin/ps" >/dev/null
      cmp "$bin/ps/brain.exe" "build/release/brain{{exe}}" && echo "ok install.ps1"
    fi

    printf x >> "$rel/brain-$os-$arch{{exe}}"; printf x >> "$rel/brain-windows-amd64.exe"
    if BRAIN_BINDIR="$bin/t" sh install.sh >/dev/null 2>&1; then echo "FAIL install.sh accepted a bad checksum"; exit 1; fi
    echo "ok install.sh refuses a bad checksum"
    if [ -n "$ps" ]; then
      if ps1 "$bin/t2" >/dev/null 2>&1; then echo "FAIL install.ps1 accepted a bad checksum"; exit 1; fi
      echo "ok install.ps1 refuses a bad checksum"
    fi

# Put the CLI on PATH and bind this machine to a vault.
install VAULT: release
    build/release/brain{{exe}} install {{VAULT}}

# The index is disposable; the markdown is canonical.
clean:
    rm -rf build "${XDG_STATE_HOME:-$HOME/.local/state}/brain"
