<#
.SYNOPSIS
  Windows-aware launcher for hisat2-build (drop-in for the `hisat2-build` script).

.DESCRIPTION
  Upstream `hisat2-build` is already Python, but assumes POSIX in two ways that
  break a bundled Windows app:

    * it names the binaries without `.exe` (`hisat2-build-s`), so they are not
      found on Windows; and
    * it dispatches with `os.execv`, which on Windows does NOT replace the
      process -- the parent returns immediately, so a caller waiting on the
      build sees it "finish" instantly with the wrong exit status.

  This PowerShell launcher keeps the wrapper's exact small-vs-large index logic
  but adds the `.exe` suffix and runs the binary as a child process so the caller
  waits for it and gets the real exit code. There is no gzip machinery here
  (hisat2-build takes plain FASTA).

  Small/large decision (mirrors upstream): use `hisat2-build-l` if
  `--large-index` is given or the total size of the reference FASTA files exceeds
  ~4 GiB; otherwise `hisat2-build-s`. `--large-index` / `--debug` / `--verbose`
  are wrapper-only flags and are not forwarded to the binary (`--debug` selects
  the `-debug` binary variant).

.NOTES
  Environment:
    HISAT2_BIN   directory holding hisat2-build-s(.exe)/hisat2-build-l(.exe)
                 (default: this script's dir, then <dir>\bin, then PATH)
    HISAT2_ECHO  if set, print the constructed command and exit without running

  Usage:
    .\hisat2_build.ps1 [options] <reference_in> <ht2_index_base>
#>

$ErrorActionPreference = 'Continue'  # native tool stderr (e.g. the alignment summary) must not throw

# Upstream threshold for switching to the large index (delta = 200).
$SmallIndexMax = 4 * [int64]1024 * 1024 * 1024 - 200

# .exe suffix only on Windows (this also runs under PowerShell 7 on macOS/Linux).
$exe = if ($env:OS -eq 'Windows_NT' -or ($IsWindows -ne $null -and $IsWindows)) { '.exe' } else { '' }

function Get-BinDir {
    param([string[]]$Stems)
    if ($env:HISAT2_BIN) { return $env:HISAT2_BIN }
    $scriptDir = $PSScriptRoot
    foreach ($d in @($scriptDir, (Join-Path $scriptDir 'bin'))) {
        foreach ($stem in $Stems) {
            if (Test-Path (Join-Path $d ($stem + $exe))) { return $d }
        }
    }
    foreach ($stem in $Stems) {
        $cmd = Get-Command ($stem + $exe) -ErrorAction SilentlyContinue
        if ($cmd) { return (Split-Path $cmd.Source) }
    }
    return $scriptDir   # let the caller emit the actionable missing-binary error
}

# ---- argument scan -----------------------------------------------------------
# Strip wrapper-only flags; everything else is forwarded to the binary.
$argv = @($args)
$forceLarge = $false
$debug = $false
$progArgs = New-Object System.Collections.Generic.List[string]

foreach ($a in $argv) {
    switch ($a) {
        '--large-index' { $forceLarge = $true }
        '--debug'       { $debug = $true }       # selects the -debug binary variant
        '--verbose'     { }                      # wrapper-only in upstream; dropped
        default         { $progArgs.Add($a) }
    }
}

$suffix = if ($debug) { '-debug' } else { '' }
$stemS = 'hisat2-build-s' + $suffix
$stemL = 'hisat2-build-l' + $suffix

# Decide small vs large. <reference_in> is the second-to-last program argument.
$useLarge = $forceLarge
if (-not $useLarge -and $progArgs.Count -ge 2) {
    $refFnames = $progArgs[$progArgs.Count - 2]
    [int64]$tot = 0
    foreach ($fn in $refFnames.Split(',')) {
        if (Test-Path -LiteralPath $fn -PathType Leaf) {
            $tot += (Get-Item -LiteralPath $fn).Length
        }
    }
    if ($tot -gt $SmallIndexMax) { $useLarge = $true }
}

$stem = if ($useLarge) { $stemL } else { $stemS }
$binDir = Get-BinDir -Stems @($stemS, $stemL)
$binary = Join-Path $binDir ($stem + $exe)
if (-not (Test-Path $binary)) { Write-Error "hisat2_build: binary not found: $binary"; exit 1 }

$final = @('--wrapper', 'basic-0') + $progArgs.ToArray()

if ($env:HISAT2_ECHO) {
    Write-Host ("{0} {1}" -f $binary, ($final -join ' '))
    exit 0
}

& $binary @final
exit $LASTEXITCODE
