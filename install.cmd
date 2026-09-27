:<<"::CMDBATCH"
@echo off
setlocal
rem brain installer: one file that is both a Windows batch script and a POSIX
rem shell script. cmd runs this half and exits before the shell half; sh
rem swallows this half as a here-document and runs the other. It downloads
rem the static binary for this machine, checks its sha256, and puts it on
rem PATH. Any arguments are passed on to `brain install`.
rem
rem   install.cmd [vault]         Windows, from cmd or PowerShell
rem   sh install.cmd [vault]      Linux, macOS, Git Bash
rem
rem BRAIN_VERSION pins a release tag; BRAIN_BINDIR picks the directory
rem (default ~/.local/bin); BRAIN_RELEASE_BASE overrides the download URL.

set "base=%BRAIN_RELEASE_BASE%"
if "%base%"=="" (
  if "%BRAIN_VERSION%"=="" (
    set "base=https://github.com/JackMordaunt/brain-cli/releases/latest/download"
  ) else (
    set "base=https://github.com/JackMordaunt/brain-cli/releases/download/%BRAIN_VERSION%"
  )
)
set "arch=amd64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "arch=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "arch=arm64"
set "asset=brain-windows-%arch%.exe"
set "bindir=%BRAIN_BINDIR%"
if "%bindir%"=="" set "bindir=%USERPROFILE%\.local\bin"
set "work=%TEMP%\brain-install-%RANDOM%%RANDOM%"
mkdir "%work%" 2>nul

echo fetching %base%/%asset%
curl.exe -fsSL -o "%work%\%asset%" "%base%/%asset%" || (echo install: download failed & rmdir /s /q "%work%" & exit /b 1)
curl.exe -fsSL -o "%work%\sha256sums.txt" "%base%/sha256sums.txt" || (echo install: no checksum file & rmdir /s /q "%work%" & exit /b 1)

set "want="
rem sha256sum writes `hash  name`, or `hash *name` for a binary on Windows.
rem No end anchor: findstr's $ and /e miss on the LF-only file CI writes.
rem Asset names are distinct and none is a substring of another.
for /f "tokens=1" %%h in ('findstr /i /c:"%asset%" "%work%\sha256sums.txt"') do set "want=%%h"
set "have="
for /f "skip=1 delims=" %%h in ('certutil -hashfile "%work%\%asset%" SHA256') do if not defined have set "have=%%h"
set "have=%have: =%"
if "%want%"=="" (echo install: %asset% is not in sha256sums.txt & rmdir /s /q "%work%" & exit /b 1)
if /i not "%have%"=="%want%" (echo install: checksum mismatch for %asset% & rmdir /s /q "%work%" & exit /b 1)

if not exist "%bindir%" mkdir "%bindir%"
move /y "%work%\%asset%" "%bindir%\brain.exe" >nul || (echo install: cannot write %bindir% & rmdir /s /q "%work%" & exit /b 1)
rmdir /s /q "%work%"
echo installed %bindir%\brain.exe
echo ;%PATH%; | findstr /i /c:";%bindir%;" >nul || echo add %bindir% to your PATH
if "%~1"=="" exit /b 0
"%bindir%\brain.exe" install %*
exit /b %ERRORLEVEL%
::CMDBATCH

# The shell half. Everything above ran as a here-document and was ignored.
set -eu

fail() { printf 'install: %s\n' "$*" >&2; exit 1; }

base=${BRAIN_RELEASE_BASE:-}
if [ -z "$base" ]; then
  if [ -n "${BRAIN_VERSION:-}" ]; then
    base="https://github.com/JackMordaunt/brain-cli/releases/download/$BRAIN_VERSION"
  else
    base="https://github.com/JackMordaunt/brain-cli/releases/latest/download"
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

# sha256sum writes `hash  name`, or `hash *name` for a binary on Windows.
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
[ $# -eq 0 ] || exec "$bindir/$name" install "$@"
