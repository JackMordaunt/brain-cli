# brain installer for Windows. It downloads the static binary for this
# machine, checks its sha256, puts it in ~/.local/bin, and runs
# `brain install`, which binds the vault named by an argument or
# BRAIN_VAULT, else the one already recorded, else ~/Documents/Brain,
# created if absent.
#
#   irm https://mordaunt.dev/code/brainfold/install.ps1 | iex
#
# Run through iex it takes no arguments, so BRAIN_VAULT names the vault, and
# it must never `exit`, which would close the caller's shell; errors are
# thrown instead. BRAIN_VERSION pins a release tag; BRAIN_BINDIR picks the
# directory; BRAIN_RELEASE_BASE overrides the download URL.

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue' # Windows PowerShell downloads crawl with it on.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $base = $env:BRAIN_RELEASE_BASE
  if (-not $base) {
    $base = if ($env:BRAIN_VERSION) {
      "https://github.com/JackMordaunt/brainfold/releases/download/$env:BRAIN_VERSION"
    } else {
      'https://github.com/JackMordaunt/brainfold/releases/latest/download'
    }
  }
  $arch = if ("$env:PROCESSOR_ARCHITECTURE $env:PROCESSOR_ARCHITEW6432" -match 'ARM64') { 'arm64' } else { 'amd64' }
  $asset = "brain-windows-$arch.exe"
  $bindir = if ($env:BRAIN_BINDIR) { $env:BRAIN_BINDIR } else { Join-Path $HOME '.local\bin' }

  # A local directory or file:// base is copied from, as curl does for the
  # shell installer; PowerShell 7's web cmdlets refuse the file scheme.
  function Get-Release($name, $to) {
    if ($base -match '^https?://') { Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $to }
    else { Copy-Item -Path (Join-Path ([uri]$base).LocalPath $name) -Destination $to }
  }

  $work = Join-Path ([IO.Path]::GetTempPath()) "brain-install-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    Write-Host "fetching $base/$asset"
    Get-Release $asset (Join-Path $work $asset)
    Get-Release 'sha256sums.txt' (Join-Path $work 'sha256sums.txt')
    $sums = Get-Content -Raw -Path (Join-Path $work 'sha256sums.txt')

    # Accept an optional * before the name, which sha256sum prints in binary mode.
    $want = $sums -split "`n" | ForEach-Object {
      $f = $_.Trim() -split '\s+\*?'
      if ($f.Count -eq 2 -and $f[1] -eq $asset) { $f[0] }
    } | Select-Object -First 1
    if (-not $want) { throw "install: $asset is not in sha256sums.txt" }
    $have = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $work $asset)).Hash
    if ($have -ne $want) { throw "install: checksum mismatch for $asset" }

    New-Item -ItemType Directory -Force -Path $bindir | Out-Null
    $exe = Join-Path $bindir 'brain.exe'
    Move-Item -Force -Path (Join-Path $work $asset) -Destination $exe
  } finally {
    Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
  }
  Write-Host "installed $exe"
  $sep = [IO.Path]::PathSeparator
  if (-not ("$sep$env:PATH$sep" -like "*$sep$bindir$sep*")) { Write-Host "add $bindir to your PATH" }

  # @(): a splatted lone string would pass one character per argument.
  $rest = @($args)
  & $exe install @rest
  if ($LASTEXITCODE -ne 0) { throw "install: brain install failed ($LASTEXITCODE)" }
} @args
