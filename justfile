# Recipes run through `sh -cu`: just ships no shell, so on Windows this needs
# Git Bash on PATH. The tool itself is one static binary and needs nothing.
#
#   just deps      fetch the jm submodule and build its SQLite archive
#   just build     debug binary with the debug allocator and ASan -> build/debug
#   just release   optimised binary                                -> build/release
#   just test      the package's tests against the fixture vault
#   just check     type-check for linux, darwin and windows, debug and release
#   just install   bind this machine to a vault
#   just logo      open the logo lab, hot-reloading tools/logo as it is edited
#   just desk      open the desk prototype, hot-reloading tools/desk
#   just hot DIR TITLE  the loop under both: any jm:ui child in a window
#   just branding  regenerate branding/ (SVG from tools/logo, PNG via rsvg-convert)
#   just proof     what a lookup costs a real agent session: vanilla, plain markdown, brain
#   just preview   render README.md and ARCHITECTURE.md to build/ and open them
#   just clean     remove build/ and the index

odin  := env("ODIN", "odin")
root  := replace(justfile_directory(), "\\", "/")
# The jm collection: https://mordaunt.dev/code/jm, pinned as the jm
# submodule. JM=<path> builds against another checkout instead.
jm    := env("JM", root / "jm")
# The commit a binary is built from, with -dirty when the tree has
# uncommitted changes, so `brain version` can say which code it is. The
# value is quoted for odin, since a hash like 21e17ac would otherwise be
# read as a number.
commit := `git rev-parse --short HEAD 2>/dev/null || echo unknown`
dirty  := `git status --porcelain 2>/dev/null | head -c 1`
stamp  := commit + (if dirty != "" { "-dirty" } else { "" })
flags := "-vet -strict-style -collection:jm=" + jm + " -define:BRAIN_TOOL=" + root + " -define:COMMIT='\"" + stamp + "\"'"
# The same without BRAIN_TOOL, which only the CLI reads: tools/logo would warn.
uiflags := "-vet -strict-style -collection:jm=" + jm
# `just build SAN=` drops the sanitizer when a library gets in its way.
san   := env("SAN", "-sanitize:address")
exe   := if os() == "windows" { ".exe" } else { "" }
# Blend2D is C++: anything linking jm:ui/render needs the runtime off Windows.
cxx_link := if os() == "windows" { "" } else { "-extra-linker-flags:\"-lstdc++\"" }
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

# The proof: what a lookup costs a real agent session with no notes, with the
# vault as plain markdown, and through brain. Needs claude logged in.
# `just proof` runs sonnet once; MODELS and REPEATS widen it.
proof: release
    tools/proof/run.sh

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

# Hot reload for the windowed tools: tools/host owns the window and DIR is
# the jm:ui child that draws into it. The child is rebuilt here every time
# one of its .odin files changes, into its own timestamped binary under
# build/hot, and named in build/<name>.watch, which the host re-reads and
# respawns from (ui/sdl.run_host). The loop is a shell one rather than
# jm's tools/hot-watch because that build omits the C++ runtime Blend2D
# needs on Linux. GNU stat and date; Linux and macOS with coreutils.
# Under Hyprland the window opens on the project's workspace, named
# <parent>/<repo> the way the rest of the desktop is (Personal/brainfold),
# or on LOGO_WORKSPACE when set; the rule lives for the session only.
#
# Open DIR's child in a hot-reloading window titled TITLE
hot DIR TITLE SIZE="1440x960": deps
    #!/usr/bin/env bash
    set -euo pipefail
    [ -e "{{jm}}"/ui/blend2d/lib/libblend2d.a ] || (cd "{{jm}}" && just blend2d)
    mkdir -p build/debug build/hot
    {{odin}} build tools/host -debug {{uiflags}} {{cxx_link}} -out:build/debug/host{{exe}}
    name=$(basename "{{DIR}}")
    pointer=build/$name.watch
    rm -f "$pointer"
    (
      last=""
      while true; do
        mt=$(stat -c %Y "{{DIR}}"/*.odin | sort -n | tail -1)
        if [ "$mt" != "$last" ]; then
          last=$mt
          out=build/hot/$name-$(date +%s%N){{exe}}
          if {{odin}} build "{{DIR}}" -debug {{uiflags}} {{cxx_link}} -out:"$out"; then
            printf '%s' "$out" > "$pointer"
            echo "hot: ready $out"
            ls -t build/hot/$name-* | tail -n +3 | xargs -r rm -f
          else
            echo "hot: build failed; the window keeps the last good build"
          fi
        fi
        sleep 0.4
      done
    ) &
    watcher=$!
    trap 'kill $watcher 2>/dev/null' EXIT
    while [ ! -f "$pointer" ]; do sleep 0.2; done
    if command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
      ws="${LOGO_WORKSPACE:-$(basename "$(dirname "{{root}}")")/$(basename "{{root}}")}"
      hyprctl eval "hl.window_rule({ match = { title = '^({{TITLE}})$' }, workspace = 'name:$ws' })" >/dev/null || true
    fi
    build/debug/host{{exe}} "$pointer" "{{TITLE}}" "{{SIZE}}"

# Open the logo lab, hot-reloading tools/logo as it is edited
logo: (hot "tools/logo" "brainfold · logo lab")

# Open the desk prototype, hot-reloading tools/desk as it is edited
desk: (hot "tools/desk" "brainfold desk" "1280x840")

# branding/ holds the mark tools/logo settled on. The SVGs come from the
# same geometry the lab draws; the PNGs are rasterised from them, so
# editing tools/logo and rerunning this is the whole workflow. Needs
# rsvg-convert (librsvg); the hero's wordmark wants JetBrains Mono installed.
#
# Regenerate branding/ from tools/logo
branding: deps
    mkdir -p build/debug branding
    {{odin}} build tools/logo -debug {{uiflags}} {{cxx_link}} -out:build/debug/logo{{exe}}
    build/debug/logo{{exe}} -svg branding
    for s in light dark; do \
      rsvg-convert -w 1024 -h 1024 branding/mark-$s.svg -o branding/mark-$s.png; \
      rsvg-convert -w 1400 -h 400 branding/hero-$s.svg -o branding/hero-$s.png; \
    done
    ls -l branding

# A local look at the docs as GitHub would show them: comrak (GitHub's
# dialect, raw HTML kept so the hero's <picture> survives) into a bare page
# under build/, with <base> pointing back at the repo so branding/ resolves.
# Follows the browser's light or dark scheme.
#
# Render README.md and ARCHITECTURE.md to build/ and open the README
preview:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    for f in README ARCHITECTURE; do
      {
        printf '<!doctype html><meta charset=utf-8><meta name=color-scheme content="light dark"><base href="../"><title>%s</title>' "$f"
        printf '<body style="max-width:52em;margin:2em auto;padding:0 1em;font:16px/1.55 system-ui;color-scheme:light dark">'
        printf '<style>pre{overflow:auto;padding:1em;background:#8881;border-radius:6px}code{font:14px ui-monospace,monospace}table{border-collapse:collapse}td,th{border:1px solid #8884;padding:.3em .6em;text-align:left}img{max-width:100%%}blockquote{margin:0;padding:0 1em;border-left:3px solid #8886;color:#888}</style>'
        comrak --gfm --unsafe "$f.md" 2>/dev/null | sed 's|href="\([A-Z]*\)\.md"|href="build/\1.html"|g'
      } > "build/$f.html"
    done
    setsid -f xdg-open build/README.html >/dev/null 2>&1 || echo "open build/README.html"

# The index is disposable; the markdown is canonical.
clean:
    rm -rf build "${XDG_STATE_HOME:-$HOME/.local/state}/brain"
