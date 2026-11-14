# Runs the test suite in the sandboxed container.
# Usage: pwsh tests/docker/test.ps1           run all tests
#        pwsh tests/docker/test.ps1 fuzz N [SEED]   run N fuzz documents
$ErrorActionPreference = 'Stop'

$image = 'oc-html-test'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$failures = Join-Path $root 'tests' 'fuzz-failures'

if ($args.Count -eq 0) {
  $command = @('lua5.3', 'tests/run.lua')
} elseif (($args.Count -eq 2 -or $args.Count -eq 3) -and $args[0] -eq 'fuzz' -and "$($args[1])" -match '^[1-9][0-9]*$' -and ($args.Count -eq 2 -or "$($args[2])" -match '^[0-9]+$')) {
  if (-not (Test-Path (Join-Path $root 'tests' 'fuzz.lua'))) {
    Write-Host 'test.ps1: fuzz not implemented: tests/fuzz.lua does not exist yet.'
    exit 1
  }
  $command = @('lua5.3', 'tests/fuzz.lua', "$($args[1])")
  if ($args.Count -eq 3) {
    $command += "$($args[2])"
  }
} else {
  Write-Host 'usage: pwsh tests/docker/test.ps1 [fuzz N [SEED]]   (N is a positive integer, SEED a whole number)'
  exit 2
}

docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "test.ps1: the image '$image' does not exist. Build it first:"
  Write-Host "  docker build -t $image tests/docker"
  exit 2
}

if (-not (Test-Path $failures)) {
  New-Item -ItemType Directory -Path $failures | Out-Null
}

# Docker Desktop accepts forward slashes in Windows mount paths.
$src = $root.Replace('\', '/')
$out = $failures.Replace('\', '/')

docker run --rm --network none --read-only `
  --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 `
  --memory 256m --pids-limit 64 `
  -v "${src}:/src:ro" -v "${out}:/src/tests/fuzz-failures" `
  -w /src $image @command
exit $LASTEXITCODE
