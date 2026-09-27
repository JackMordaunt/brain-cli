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
test: build
    mkdir -p build/test
    {{odin}} test brain {{san}} {{flags}} -define:ODIN_TEST_THREADS=1 -out:build/test/brain{{exe}}
    @for f in bin/hooks/* bin/shims/*; do bash -n "$f" && echo "ok $f"; done

# Put the CLI on PATH and bind this machine to a vault.
install VAULT: release
    build/release/brain{{exe}} install {{VAULT}}

# The index is disposable; the markdown is canonical.
clean:
    rm -rf build "${XDG_STATE_HOME:-$HOME/.local/state}/brain"
