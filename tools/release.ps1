# Publishes a release under releases/<version> and points releases/latest at it.
# Usage: pwsh tools/release.ps1 <version>     for example: pwsh tools/release.ps1 0.0.1a
# Version: major.minor.patch, with suffix a (alpha), b (beta) or none (release).
$ErrorActionPreference = 'Stop'

function Fail($message) {
  Write-Host "release.ps1: $message"
  exit 1
}

if ($args.Count -ne 1) {
  Write-Host 'usage: pwsh tools/release.ps1 <version>   (for example 0.0.1a)'
  exit 2
}
$version = "$($args[0])"
if ($version -notmatch '^\d+\.\d+\.\d+[ab]?$') {
  Fail "bad version '$version'. Use major.minor.patch with an optional suffix a or b, for example 0.0.1a."
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

$releases = Join-Path $root 'releases'
$target = Join-Path $releases $version
if (Test-Path -LiteralPath $target) {
  Fail "releases/$version already exists. A release is never overwritten."
}

$dirty = git status --porcelain -- bin lib
if ($LASTEXITCODE -ne 0) { Fail 'git status failed.' }
if ($dirty) {
  Write-Host $dirty
  Fail 'bin/ or lib/ has uncommitted changes. Commit them first, so the release matches a commit.'
}
$commit = (git rev-parse HEAD).Trim()

& pwsh (Join-Path $root 'tests' 'docker' 'test.ps1')
if ($LASTEXITCODE -ne 0) { Fail 'tests failed. No release made.' }

$binDir = Join-Path $target 'bin'
$libDir = Join-Path $target 'lib' 'html'
New-Item -ItemType Directory -Force $binDir, $libDir | Out-Null
Copy-Item (Join-Path $root 'bin' 'html.lua') $binDir
Copy-Item (Join-Path $root 'lib' 'html' '*.lua') $libDir

# files.txt lists the other files, not itself.
$files = Get-ChildItem -Recurse -File $target |
  ForEach-Object { $_.FullName.Substring($target.Length + 1).Replace('\', '/') } |
  Sort-Object { $_ } -CaseSensitive
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $target 'files.txt'), (($files -join "`n") + "`n"), $utf8)

$link = Join-Path $releases 'latest'
if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Recurse -Force }
git rm --cached -q --ignore-unmatch -- releases/latest 2>$null | Out-Null

$method = $null
if ((git config core.symlinks) -eq 'true') {
  try {
    New-Item -ItemType SymbolicLink -Path $link -Target $version -ErrorAction Stop | Out-Null
    $method = 'file-system symlink'
  } catch {
    $method = $null
  }
}
if (-not $method) {
  $tmp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllBytes($tmp, $utf8.GetBytes($version))
    $hash = (git hash-object -w $tmp).Trim()
  } finally {
    Remove-Item -LiteralPath $tmp -Force
  }
  git update-index --add --cacheinfo "120000,$hash,releases/latest"
  if ($LASTEXITCODE -ne 0) { Fail 'could not record releases/latest in the git index.' }
  $method = 'git index only'
  Write-Host 'note: releases/latest exists in git only. No file-system link was made.'
}

Write-Host "release folder: releases/$version"
Write-Host 'files:'
$files | ForEach-Object { Write-Host "  $_" }
Write-Host "built from commit: $commit"
Write-Host "latest -> $version ($method)"
