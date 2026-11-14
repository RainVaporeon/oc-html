# Publishes a release under releases/<version> and points releases/latest at it.
# Usage: pwsh tools/release.ps1 <version>     for example: pwsh tools/release.ps1 0.0.1a
# Version: major.minor.patch, with suffix a (alpha), b (beta) or none (release).
# Usage: pwsh tools/release.ps1 -TarballOnly <version>
#   Only adds release.tar.gz to an existing release folder that has none.
# A new release also gets html-install.lua, a one-file installer made by
# tools/mkinstall.lua in the test container. files.txt does not list it.
param(
  [Parameter(Position = 0)][string]$Version,
  [string]$TarballOnly
)
$ErrorActionPreference = 'Stop'

# Set while this run owns a new release folder that is not finished.
$script:created = $null

function Fail($message) {
  Write-Host "release.ps1: $message"
  if ($script:created) {
    Remove-Item -LiteralPath $script:created -Recurse -Force -ErrorAction SilentlyContinue
  }
  exit 1
}

# Creates releases/<version>/release.tar.gz from the files in files.txt, then checks it:
# the archive list equals files.txt and every extracted file equals the release copy.
function New-ReleaseTarball($target) {
  $tar = Join-Path $env:SystemRoot 'System32' 'tar.exe'
  if (-not (Test-Path -LiteralPath $tar)) { Fail "$tar not found (bsdtar is needed)." }
  $listFile = Join-Path $target 'files.txt'
  $archive = Join-Path $target 'release.tar.gz'
  if (-not (Test-Path -LiteralPath $listFile)) { Fail "$listFile not found." }
  if (Test-Path -LiteralPath $archive) { Fail 'release.tar.gz already exists. It is never overwritten.' }
  $expected = @(Get-Content -LiteralPath $listFile | Where-Object { $_ -ne '' })

  # Names come from files.txt in sorted order. ustar format, owner and group 0, no names.
  & $tar --format ustar --uid 0 --gid 0 --uname '' --gname '' -czf $archive -C $target -T $listFile
  if ($LASTEXITCODE -ne 0) { Fail 'tar failed to create release.tar.gz.' }

  $listed = @(& $tar -tzf $archive)
  if ($LASTEXITCODE -ne 0) { Fail 'tar failed to list release.tar.gz.' }
  if (($listed -join "`n") -cne ($expected -join "`n")) {
    Fail "release.tar.gz list differs from files.txt.`nlisted:`n$($listed -join "`n")"
  }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("oc-html-tar-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $tmp | Out-Null
  try {
    & $tar -xzf $archive -C $tmp
    if ($LASTEXITCODE -ne 0) { Fail 'tar failed to extract release.tar.gz.' }
    foreach ($name in $expected) {
      $a = Join-Path $target $name
      $b = Join-Path $tmp $name
      if (-not (Test-Path -LiteralPath $b)) { Fail "extracted file missing: $name" }
      $x = [IO.File]::ReadAllBytes($a)
      $y = [IO.File]::ReadAllBytes($b)
      if ($x.Length -ne $y.Length -or [System.Linq.Enumerable]::SequenceEqual([byte[]]$x, [byte[]]$y) -eq $false) {
        Fail "extracted file differs from the release copy: $name"
      }
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
  }
  Write-Host 'release.tar.gz:'
  $listed | ForEach-Object { Write-Host "  $_" }
  Write-Host "release.tar.gz size: $((Get-Item -LiteralPath $archive).Length) bytes"
}

# Runs a command in the test container with the sandbox flags of
# tests/docker/test.ps1. The repository is mounted read-only.
function Invoke-Sandbox {
  $src = $root.Replace('\', '/')
  docker run --rm --network none --read-only `
    --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 `
    --memory 256m --pids-limit 64 `
    -v "${src}:/src:ro" -w /src oc-html-test @args
}

# Creates releases/<version>/html-install.lua from files.txt with
# tools/mkinstall.lua, then checks its syntax with luac5.3 and compares the
# embedded files with the release copies.
function New-ReleaseInstaller($version, $target) {
  $installer = Join-Path $target 'html-install.lua'
  if (Test-Path -LiteralPath $installer) { Fail 'html-install.lua already exists. It is never overwritten.' }
  $tmp = "$installer.tmp"
  # pwsh 7.4 and later keep the bytes only when a native command is
  # redirected directly. Output from a function goes through the pipeline as
  # text lines and gets CRLF endings, so docker is called here, not
  # Invoke-Sandbox.
  $src = $root.Replace('\', '/')
  docker run --rm --network none --read-only `
    --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 `
    --memory 256m --pids-limit 64 `
    -v "${src}:/src:ro" -w /src oc-html-test `
    lua5.3 tools/mkinstall.lua $version "releases/$version" > $tmp
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Fail 'tools/mkinstall.lua failed. No installer made.'
  }
  # Lua reads CRLF in a long string as LF, so the checks below would not see
  # it. The file must have the exact generator bytes.
  if ([IO.File]::ReadAllBytes($tmp) -contains [byte]13) {
    Remove-Item -LiteralPath $tmp -Force
    Fail 'the installer output has a carriage return. No installer made.'
  }
  Move-Item -LiteralPath $tmp $installer
  Invoke-Sandbox luac5.3 -p "releases/$version/html-install.lua"
  if ($LASTEXITCODE -ne 0) { Fail 'html-install.lua failed the luac5.3 syntax check.' }
  Invoke-Sandbox lua5.3 tools/mkinstall.lua --check $version "releases/$version"
  if ($LASTEXITCODE -ne 0) { Fail 'html-install.lua differs from the release files.' }
  Write-Host "html-install.lua size: $((Get-Item -LiteralPath $installer).Length) bytes"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

if ($TarballOnly -and $Version) {
  Write-Host 'usage: pwsh tools/release.ps1 <version>   or   pwsh tools/release.ps1 -TarballOnly <version>'
  exit 2
}
if (-not $TarballOnly -and -not $Version) {
  Write-Host 'usage: pwsh tools/release.ps1 <version>   (for example 0.0.1a)'
  exit 2
}
$version = if ($TarballOnly) { $TarballOnly } else { $Version }
if ($version -notmatch '^\d+\.\d+\.\d+[ab]?$') {
  Fail "bad version '$version'. Use major.minor.patch with an optional suffix a or b, for example 0.0.1a."
}

$releases = Join-Path $root 'releases'
$target = Join-Path $releases $version

if ($TarballOnly) {
  if (-not (Test-Path -LiteralPath $target)) { Fail "releases/$version does not exist." }
  New-ReleaseTarball $target
  exit 0
}

if (Test-Path -LiteralPath $target) {
  Fail "releases/$version already exists. A release is never overwritten."
}

$dirty = git status --porcelain -- bin lib tools/installer.lua tools/mkinstall.lua
if ($LASTEXITCODE -ne 0) { Fail 'git status failed.' }
if ($dirty) {
  Write-Host $dirty
  Fail 'bin/, lib/ or the installer tools have uncommitted changes. Commit them first, so the release matches a commit.'
}
$commit = (git rev-parse HEAD).Trim()

& pwsh (Join-Path $root 'tests' 'docker' 'test.ps1')
if ($LASTEXITCODE -ne 0) { Fail 'tests failed. No release made.' }

$binDir = Join-Path $target 'bin'
$libDir = Join-Path $target 'lib' 'html'
# Only the folder this run creates is removed on a failure.
New-Item -ItemType Directory -Path $target | Out-Null
$script:created = $target
try {
  New-Item -ItemType Directory -Force $binDir, $libDir | Out-Null
  Copy-Item (Join-Path $root 'bin' 'html.lua') $binDir
  Copy-Item (Join-Path $root 'lib' 'html' '*.lua') $libDir

  # files.txt lists the other files, not itself.
  $files = Get-ChildItem -Recurse -File $target |
    ForEach-Object { $_.FullName.Substring($target.Length + 1).Replace('\', '/') } |
    Sort-Object { $_ } -CaseSensitive
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $target 'files.txt'), (($files -join "`n") + "`n"), $utf8)

  New-ReleaseTarball $target
  New-ReleaseInstaller $version $target

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
} catch {
  $err = $_.Exception.Message
  Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
  Fail "release failed, releases/$version removed: $err"
}
$script:created = $null

Write-Host "release folder: releases/$version"
Write-Host 'files:'
$files | ForEach-Object { Write-Host "  $_" }
Write-Host "installer: releases/$version/html-install.lua"
Write-Host "built from commit: $commit"
Write-Host "latest -> $version ($method)"
