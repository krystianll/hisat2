<#
.SYNOPSIS
  Perl-free launcher for HISAT2 alignment (drop-in for the `hisat2` wrapper).

.DESCRIPTION
  A PowerShell replacement for the upstream Perl `hisat2` wrapper, for bundled
  apps that have no Perl. It reproduces the wrapper's behavior:

    1. picks hisat2-align-s vs hisat2-align-l from the index (or --large-index),
       and the -debug variant with --debug;
    2. forwards every other option to the aligner with `--wrapper basic-0`;
    3. implements the read-redirection options --un / --al / --un-conc /
       --al-conc / --al-conc-disc (and their -gz / -bz2 compressed variants),
       and --no-unal, which the align BINARY does not handle itself -- the
       wrapper drives them via the binary's `--passthrough` mode.

  Native gzip input means .gz reads (files or stdin "-") need no decompression
  here; those are passed straight through and handled by the binary.

  Compression of redirected reads: -gz is produced natively via .NET
  (System.IO.Compression). -bz2 requires `bzip2` on PATH (rare); without it the
  launcher errors and asks you to use -gz. As in the Perl wrapper, a compressed
  output keeps the plain mangled filename (e.g. out.1.fq holding gzip data); no
  .gz suffix is added.

.NOTES
  Environment:
    HISAT2_BIN   directory holding hisat2-align-s(.exe)/hisat2-align-l(.exe)
                 (default: this script's dir, then <dir>\bin, then PATH)
    HISAT2_ECHO  if set, print the constructed binary command and exit

  Usage:
    .\hisat2.ps1 -x <index> -1 r1.fq.gz -2 r2.fq.gz -S out.sam [opts]
    .\hisat2.ps1 -x <index> -U reads.fq.gz --un-gz unaligned.fq -S out.sam
#>

$ErrorActionPreference = 'Continue'  # native tool stderr (e.g. the alignment summary) must not throw

# .exe suffix only on Windows (this also runs under PowerShell 7 on macOS/Linux).
$exe = if ($env:OS -eq 'Windows_NT' -or ($IsWindows -ne $null -and $IsWindows)) { '.exe' } else { '' }

# ISO-8859-1: a 1:1 byte<->char mapping so read/quality bytes survive verbatim.
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)

# GZipStream lives in System.IO.Compression.dll, not loaded by default in
# Windows PowerShell 5.1 (it is built in under PowerShell 7).
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

function Get-BinDir {
    if ($env:HISAT2_BIN) { return $env:HISAT2_BIN }
    $scriptDir = $PSScriptRoot
    foreach ($d in @($scriptDir, (Join-Path $scriptDir 'bin'))) {
        foreach ($stem in @('hisat2-align-s', 'hisat2-align-l')) {
            if (Test-Path (Join-Path $d ($stem + $exe))) { return $d }
        }
    }
    foreach ($stem in @('hisat2-align-s', 'hisat2-align-l')) {
        $cmd = Get-Command ($stem + $exe) -ErrorAction SilentlyContinue
        if ($cmd) { return (Split-Path $cmd.Source) }
    }
    return $scriptDir   # let Resolve-Aligner emit the actionable error
}

function Resolve-Aligner {
    param([string]$Index, [bool]$ForceLarge, [bool]$UseDebug)
    $binDir = Get-BinDir
    $suffix = if ($UseDebug) { '-debug' } else { '' }
    $small = Join-Path $binDir ('hisat2-align-s' + $suffix + $exe)
    $large = Join-Path $binDir ('hisat2-align-l' + $suffix + $exe)
    # Mirror the Perl wrapper: default to the small aligner, switch to large only
    # when forced or when only the large index exists. Do NOT hard-fail on a
    # missing index -- with no -x (e.g. -h/--help/--version/no args) we still run
    # the binary so it prints its own usage/version, exactly like the wrapper.
    if ($ForceLarge) {
        if ($Index -and -not (Test-Path ($Index + '.1.ht2l'))) {
            Write-Error "hisat2: --large-index given but $Index.1.ht2l not found"; exit 1
        }
        Write-Info "Using a large index enforced by user."
        $chosen = $large
    } elseif ($Index -and (Test-Path ($Index + '.1.ht2l')) -and -not (Test-Path ($Index + '.1.ht2'))) {
        Write-Info "Cannot find a small index but a large one seems to be present."
        Write-Info "Switching to using the large index (${Index}.1.ht2l)."
        $chosen = $large
    } else {
        if ($Index) { Write-Info "Using the small index (${Index}.1.ht2)." }
        $chosen = $small
    }
    if (-not (Test-Path $chosen)) { Write-Error "hisat2: aligner binary not found: $chosen"; exit 1 }
    return $chosen
}

# Verbose (INFO) logging to stderr, gated on --verbose, mirroring the Perl
# wrapper's Info() -- including the exact command signature it is about to run.
# (No custom usage/help: like the Perl wrapper, -h/--help/--version and the
# no-argument case are handled by the aligner binary itself, which prints the
# full HISAT2 usage and, on error, we echo "(ERR): hisat2-align exited ...".)
$verbose = $false
function Write-Info {
    param([string]$msg)
    if ($verbose) { [Console]::Error.WriteLine("(INFO): $msg") }
}

# Mangle a --*-conc target into its mate-1/mate-2 names (mirrors the Perl wrapper).
function Get-ConcNames {
    param([string]$target)
    $dir  = [System.IO.Path]::GetDirectoryName($target)
    $name = [System.IO.Path]::GetFileName($target)
    if ($name -match '%') {
        $n1 = $name -replace '%', '1'; $n2 = $name -replace '%', '2'
    } elseif ($name -match '\.[^.]*$') {
        $n1 = $name -replace '\.([^.]*)$', '.1.$1'
        $n2 = $name -replace '\.([^.]*)$', '.2.$1'
    } else {
        $n1 = "$name.1"; $n2 = "$name.2"
    }
    if ($dir) { return @((Join-Path $dir $n1), (Join-Path $dir $n2)) }
    return @($n1, $n2)
}

# Open a StreamWriter for a redirected-read file, applying gzip on the fly.
# For bzip2, write plain to a temp file and record it for post-compression.
function New-ReadWriter {
    param([string]$path, [string]$compress, [System.Collections.Generic.List[object]]$bz2jobs)
    if ($compress -eq 'gzip') {
        $fs = [System.IO.File]::Create($path)
        $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Compress)
        return New-Object System.IO.StreamWriter($gz, $Latin1)
    } elseif ($compress -eq 'bzip2') {
        $tmp = "$path.hisat2bz2.tmp"
        $bz2jobs.Add(@{ Tmp = $tmp; Final = $path })
        return New-Object System.IO.StreamWriter($tmp, $false, $Latin1)
    } else {
        return New-Object System.IO.StreamWriter($path, $false, $Latin1)
    }
}

function Unescape-Read {
    param([string]$s)
    return [regex]::Replace($s, '%([0-9A-Fa-f]{2})', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

# ---- argument scan -----------------------------------------------------------
# No help short-circuit: -h/--help/--version and the no-argument case fall
# through to the binary (which prints the full HISAT2 usage), like the Perl wrapper.
$argv = @($args)

$index      = $null
$forceLarge = $false
$useDebug   = $false
$noUnal     = $false
$capOut     = $null
$readFns    = @{}                 # key (un/al/un-conc/al-conc/al-conc-disc) -> @{ Path; Compress }
$passthru   = New-Object System.Collections.Generic.List[string]

$readOptRe = '^(al-conc-disc|un-conc|al-conc|un|al)(-gz|-bz2)?$'

for ($i = 0; $i -lt $argv.Count; $i++) {
    $a = $argv[$i]

    if ($a -eq '--large-index') { $forceLarge = $true; continue }   # dispatch, consumed
    if ($a -eq '--debug')       { $useDebug   = $true; continue }   # -debug variant, consumed
    if ($a -eq '--no-unal')     { $noUnal     = $true; continue }   # handled in wrapper (see below)
    if ($a -eq '--verbose')     { $verbose    = $true; $passthru.Add($a); continue }  # INFO here + forward to binary

    # Index (needed to choose s/l): recognized but still forwarded.
    if ($a -eq '-x' -or $a -eq '--index') {
        if ($i + 1 -ge $argv.Count) { Write-Error "hisat2: $a requires an argument"; exit 1 }
        $index = $argv[$i + 1]; $passthru.Add($a); $passthru.Add($argv[$i + 1]); $i++; continue
    }
    if ($a.StartsWith('-x') -and $a.Length -gt 2)  { $index = $a.Substring(2); $passthru.Add($a); continue }
    if ($a.StartsWith('--index='))                 { $index = $a.Substring(8); $passthru.Add($a); continue }

    # Output SAM: captured; only forwarded to the binary if we do NOT post-process.
    if ($a -eq '-S' -or $a -eq '--output') {
        if ($i + 1 -ge $argv.Count) { Write-Error "hisat2: $a requires an argument"; exit 1 }
        $capOut = $argv[$i + 1]; $i++; continue
    }
    if ($a.StartsWith('-S') -and $a.Length -gt 2)  { $capOut = $a.Substring(2); continue }
    if ($a.StartsWith('--output='))                { $capOut = $a.Substring(9); continue }

    # Read-redirection options (wrapper-only; the binary rejects these).
    if ($a.StartsWith('--')) {
        $body = $a.Substring(2)
        $eq = $body.IndexOf('=')
        $optName = if ($eq -ge 0) { $body.Substring(0, $eq) } else { $body }
        if ($optName -match $readOptRe) {
            $base = $Matches[1]
            $comp = switch ($Matches[2]) { '-gz' { 'gzip' } '-bz2' { 'bzip2' } default { 'none' } }
            if ($eq -ge 0) {
                $val = $body.Substring($eq + 1)
            } else {
                if ($i + 1 -ge $argv.Count) { Write-Error "hisat2: --$optName requires an argument"; exit 1 }
                $val = $argv[$i + 1]; $i++
            }
            $readFns[$base] = @{ Path = $val; Compress = $comp }
            continue
        }
    }

    $passthru.Add($a)
}

$binary   = Resolve-Aligner -Index $index -ForceLarge $forceLarge -UseDebug $useDebug
$passOn   = $passthru.ToArray()
$doPass   = ($readFns.Count -gt 0)

# ---- simple path: no read redirection ---------------------------------------
if (-not $doPass) {
    $final = @('--wrapper', 'basic-0') + $passOn
    if ($noUnal) { $final += '--no-unal' }              # binary handles it natively here
    if ($capOut) { $final += @('-S', $capOut) }
    if ($env:HISAT2_ECHO) { Write-Host ("{0} {1}" -f $binary, ($final -join ' ')); exit 0 }
    Write-Info ("'{0}' {1}" -f $binary, ($final -join ' '))   # command signature (verbose)
    & $binary @final
    $code = $LASTEXITCODE
    if ($code -ne 0) { [Console]::Error.WriteLine("(ERR): hisat2-align exited with value $code") }
    exit $code
}

# ---- passthrough path: demultiplex reads into --un/--al/... files ------------
# --no-unal is NOT passed to the binary here: we still need every record (incl.
# unaligned) emitted so their reads can be routed; we filter them from the SAM
# output ourselves, exactly as the Perl wrapper does.
$final = @('--wrapper', 'basic-0', '--passthrough') + $passOn

if ($env:HISAT2_ECHO) {
    Write-Host ("{0} {1}   (+ wrapper demux of: {2})" -f $binary, ($final -join ' '), ($readFns.Keys -join ','))
    exit 0
}
Write-Info ("'{0}' {1}" -f $binary, ($final -join ' '))   # command signature (verbose)

# Open the redirected-read writers (with mangling for the -conc pairs).
$bz2jobs = New-Object System.Collections.Generic.List[object]
$writers = @{}   # key -> writer (single) OR @{1=w1; 2=w2} (conc)
foreach ($k in $readFns.Keys) {
    $spec = $readFns[$k]
    if ($k -like '*-conc' -or $k -like '*-conc-disc') {
        $names = Get-ConcNames $spec.Path
        $writers[$k] = @{
            1 = (New-ReadWriter $names[0] $spec.Compress $bz2jobs)
            2 = (New-ReadWriter $names[1] $spec.Compress $bz2jobs)
        }
    } else {
        $writers[$k] = (New-ReadWriter $spec.Path $spec.Compress $bz2jobs)
    }
}

# SAM output sink (captured -S file, or stdout).
if ($capOut) {
    $samStream = [System.IO.File]::Create($capOut)
} else {
    $samStream = [System.Console]::OpenStandardOutput()
}
$samWriter = New-Object System.IO.StreamWriter($samStream, $Latin1)

# Byte-faithful decode of the binary's stdout.
$prevOutEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = $Latin1

$awaiting = $false      # next line is the read for the pending record
$pendSam  = $null
$pendFlag = 0

try {
    & $binary @final | ForEach-Object {
        $line = $_
        if ($awaiting) {
            $read = Unescape-Read $line
            $secondary = ($pendFlag -band 256) -ne 0
            $mate1 = ($pendFlag -band 64)  -ne 0
            $mate2 = ($pendFlag -band 128) -ne 0
            $unp   = (-not $mate1) -and (-not $mate2)
            if (-not $secondary) {
                if ($unp) {
                    if (($pendFlag -band 4) -ne 0) {
                        if ($writers.ContainsKey('un')) { $writers['un'].Write($read) }
                    } else {
                        if ($writers.ContainsKey('al')) { $writers['al'].Write($read) }
                    }
                } else {
                    $conc = ($pendFlag -band 2) -ne 0
                    $concDisc = (($pendFlag -band 4) -eq 0) -or (($pendFlag -band 8) -eq 0)
                    if ($conc -and $mate1)      { if ($writers.ContainsKey('al-conc')) { $writers['al-conc'][1].Write($read) } }
                    elseif ($conc -and $mate2)  { if ($writers.ContainsKey('al-conc')) { $writers['al-conc'][2].Write($read) } }
                    elseif ((-not $conc) -and $mate1) { if ($writers.ContainsKey('un-conc')) { $writers['un-conc'][1].Write($read) } }
                    elseif ((-not $conc) -and $mate2) { if ($writers.ContainsKey('un-conc')) { $writers['un-conc'][2].Write($read) } }
                    if ($concDisc -and $mate1)      { if ($writers.ContainsKey('al-conc-disc')) { $writers['al-conc-disc'][1].Write($read) } }
                    elseif ($concDisc -and $mate2)  { if ($writers.ContainsKey('al-conc-disc')) { $writers['al-conc-disc'][2].Write($read) } }
                }
            }
            # Emit the held SAM record unless --no-unal filters it.
            if (-not ($noUnal -and (($pendFlag -band 4) -ne 0))) {
                $samWriter.Write($pendSam); $samWriter.Write("`n")
            }
            $awaiting = $false
        }
        elseif ($line.Length -gt 0 -and $line[0] -eq '@') {
            $samWriter.Write($line); $samWriter.Write("`n")     # header
        }
        else {
            $t1 = $line.IndexOf("`t") + 1
            $t2 = $line.IndexOf("`t", $t1)
            $pendFlag = [int]$line.Substring($t1, $t2 - $t1)
            $pendSam  = $line
            $awaiting = $true
        }
    }
    $code = $LASTEXITCODE
}
finally {
    [Console]::OutputEncoding = $prevOutEnc
    $samWriter.Flush(); $samWriter.Dispose()
    foreach ($k in $writers.Keys) {
        $w = $writers[$k]
        if ($w -is [hashtable]) { $w[1].Flush(); $w[1].Dispose(); $w[2].Flush(); $w[2].Dispose() }
        else { $w.Flush(); $w.Dispose() }
    }
}

# Post-compress any bzip2 outputs (native gzip already done on the fly).
if ($bz2jobs.Count -gt 0) {
    $bz = Get-Command bzip2 -ErrorAction SilentlyContinue
    if (-not $bz) {
        foreach ($j in $bz2jobs) { Remove-Item -Force $j.Tmp -ErrorAction SilentlyContinue }
        Write-Error "hisat2: -bz2 output requires 'bzip2' on PATH; re-run with -gz instead."
        exit 1
    }
    foreach ($j in $bz2jobs) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $bz.Source
        $psi.Arguments = '-c'
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $inBytes = [System.IO.File]::ReadAllBytes($j.Tmp)
        $p.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
        $p.StandardInput.Close()
        $outfs = [System.IO.File]::Create($j.Final)
        $p.StandardOutput.BaseStream.CopyTo($outfs)
        $outfs.Dispose()
        $p.WaitForExit()
        Remove-Item -Force $j.Tmp -ErrorAction SilentlyContinue
    }
}

if ($code -ne 0) { [Console]::Error.WriteLine("(ERR): hisat2-align exited with value $code") }
exit $code
