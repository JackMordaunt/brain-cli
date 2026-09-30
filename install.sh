#!/bin/sh
# brain installer for Linux, macOS and Git Bash. It downloads the static
# binary for this machine, checks its sha256, puts it on PATH, and runs
# `brain install`, which binds the vault named by an argument or
# BRAIN_VAULT, else the one already recorded, else ~/Documents/Brain,
# created if absent.
#
#   curl -fsSL https://mordaunt.dev/code/brainfold/install.sh | sh
#   curl -fsSL https://mordaunt.dev/code/brainfold/install.sh | sh -s -- <vault>
#
# BRAIN_VERSION pins a release tag; BRAIN_BINDIR picks the directory
# (default ~/.local/bin); BRAIN_RELEASE_BASE overrides the download URL.

set -eu

fail() { printf 'install: %s\n' "$*" >&2; exit 1; }

base=${BRAIN_RELEASE_BASE:-}
if [ -z "$base" ]; then
  if [ -n "${BRAIN_VERSION:-}" ]; then
    base="https://github.com/JackMordaunt/brainfold/releases/download/$BRAIN_VERSION"
  else
    base="https://github.com/JackMordaunt/brainfold/releases/latest/download"
  fi
fi

case "$(uname -s)" in
  Linux*)                os=linux ;;
  Darwin*)               os=darwin ;;
  MINGW*|MSYS*|CYGWIN*)  os=windows ;;
  *)                     fail "unsupported system: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)   arch=amd64 ;;
  aarch64|arm64)  arch=arm64 ;;
  *)              fail "unsupported architecture: $(uname -m)" ;;
esac
asset="brain-$os-$arch"
name=brain
if [ "$os" = windows ]; then asset="$asset.exe"; name=brain.exe; fi
bindir=${BRAIN_BINDIR:-$HOME/.local/bin}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else fail "neither curl nor wget is installed"; fi
}
printf 'fetching %s/%s\n' "$base" "$asset"
fetch "$base/$asset" "$work/$asset" || fail "download failed"
fetch "$base/sha256sums.txt" "$work/sha256sums.txt" || fail "no checksum file"

# Accept an optional * before the name, which sha256sum prints in binary mode.
want=$(grep "[[:space:]]\*\{0,1\}$asset\$" "$work/sha256sums.txt" | cut -d' ' -f1)
[ -n "$want" ] || fail "$asset is not in sha256sums.txt"
if command -v sha256sum >/dev/null 2>&1; then have=$(sha256sum "$work/$asset" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then have=$(shasum -a 256 "$work/$asset" | cut -d' ' -f1)
else fail "neither sha256sum nor shasum is installed"; fi
[ "$have" = "$want" ] || fail "checksum mismatch for $asset"

mkdir -p "$bindir"
mv -f "$work/$asset" "$bindir/$name"
chmod +x "$bindir/$name"
printf 'installed %s/%s\n' "$bindir" "$name"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) printf 'add %s to your PATH\n' "$bindir" ;;
esac
exec "$bindir/$name" install "$@"
