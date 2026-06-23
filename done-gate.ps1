# done-gate.ps1 - proof receipts for AI coding agents.
#
# Native PowerShell port of done-gate.sh. Supports Windows PowerShell 5.1 and
# PowerShell 7+ with built-ins only.

$ErrorActionPreference = 'Stop'

function Write-Stderr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Die {
    param([string]$Message)
    Write-Stderr "done-gate: $Message"
    exit 2
}

function Usage {
    @'
done-gate.ps1 - proof receipts for AI coding agents.

Subcommands:
  capture --label L [--run R] [--json] -- CMD [ARGS...]
  assert  [--label L ...] [--run R] [--ttl S] [--allow-command-regex RE] [--json]
  verify  --label L [--run R] [--json] --sha HEX
  show    [--run R] [--json]
  -h | --help | help
'@
}

function Get-Root {
    $pwdPath = (Get-Location).ProviderPath
    try {
        $root = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $root) {
            return ([string]$root).Trim()
        }
    } catch {
    }
    return $pwdPath
}

function Test-ValidName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name.Contains('..')) { return $false }
    return ($Name -match '^[A-Za-z0-9._-]+$')
}

function Json-Escape {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    # Match the Bash ledger contract: only escape slash/quote and flatten
    # control whitespace so hand-built JSONL remains compact and stable.
    $Value = $Value -replace '\\', '\\'
    $Value = $Value -replace '"', '\"'
    $Value = $Value -replace "[`r`n`t]", ' '
    return $Value
}

function Get-Utf8NoBom {
    return (New-Object System.Text.UTF8Encoding($false))
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Value
    )
    [System.IO.File]::WriteAllText($Path, $Value, (Get-Utf8NoBom))
}

function Append-TextLine {
    param(
        [string]$Path,
        [string]$Value
    )
    [System.IO.File]::AppendAllText($Path, $Value + [Environment]::NewLine, (Get-Utf8NoBom))
}

function Get-UtcStamp {
    return ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture))
}

function Get-RunStamp {
    return ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture))
}

function Get-UnixEpoch {
    param([DateTime]$UtcNow)
    $origin = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [int64][Math]::Floor(($UtcNow.ToUniversalTime() - $origin).TotalSeconds)
}

function Get-Sha256OfFile {
    param([string]$Path)
    return ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant())
}

function Get-RelativeLogPath {
    param(
        [string]$Root,
        [string]$LogPath
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $logFull = [IO.Path]::GetFullPath($LogPath)
    $relative = $logFull
    $prefix1 = $rootFull + [IO.Path]::DirectorySeparatorChar
    $prefix2 = $rootFull + [IO.Path]::AltDirectorySeparatorChar
    if ($logFull.StartsWith($prefix1, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $logFull.Substring($prefix1.Length)
    } elseif ($logFull.StartsWith($prefix2, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $logFull.Substring($prefix2.Length)
    }
    return ($relative -replace '\\', '/')
}

function Resolve-RunForRead {
    param(
        [AllowNull()][string]$Run,
        [string]$ProofDir
    )
    if (-not [string]::IsNullOrEmpty($Run)) { return $Run }
    $latest = Join-Path $ProofDir 'latest'
    if (Test-Path -LiteralPath $latest) {
        return ((Get-Content -Raw -LiteralPath $latest) -replace "[`r`n]+$", '')
    }
    return ''
}

function Latest-ForLabel {
    param(
        [string]$Ledger,
        [string]$Label
    )
    if (-not (Test-Path -LiteralPath $Ledger)) { return '' }
    $needle = '"label":"' + (Json-Escape $Label) + '"'
    $matches = @(Get-Content -LiteralPath $Ledger | Where-Object { $_.Contains($needle) })
    if ($matches.Count -eq 0) { return '' }
    return [string]$matches[$matches.Count - 1]
}

function Rec-Field {
    param(
        [string]$Line,
        [string]$Pattern
    )
    $m = [regex]::Match($Line, $Pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Receipt-ExitCode {
    param([string]$Line)
    return (Rec-Field $Line '"exit_code":([0-9]+)')
}

function Receipt-Epoch {
    param([string]$Line)
    return (Rec-Field $Line '"epoch":([0-9]+)')
}

function Receipt-Sha {
    param([string]$Line)
    return (Rec-Field $Line '"sha256":"([0-9a-f]+)"')
}

function Receipt-Command {
    param([string]$Line)
    return (Rec-Field $Line '"command":"(.*)","exit_code":')
}

function Receipt-Label {
    param([string]$Line)
    return (Rec-Field $Line '"label":"([^"]*)"')
}

function Command-Text {
    param([string[]]$Command)
    return ($Command -join ' ')
}

function Capture-Command {
    param(
        [string[]]$Command,
        [string]$LogPath
    )
    $cmd = $Command[0]
    $cmdArgs = @()
    if ($Command.Count -gt 1) {
        $cmdArgs = @($Command[1..($Command.Count - 1)])
    }

    $writer = New-Object System.IO.StreamWriter($LogPath, $false, (Get-Utf8NoBom))
    try {
        # Run the native command directly so PowerShell preserves $LASTEXITCODE.
        # The pipeline tees combined stdout/stderr to the console and UTF-8 log.
        & $cmd @cmdArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            [Console]::Out.WriteLine($line)
            $writer.WriteLine($line)
        }
        $rc = $LASTEXITCODE
        if ($null -eq $rc) {
            if ($?) { $rc = 0 } else { $rc = 1 }
        }
        return [int]$rc
    } finally {
        $writer.Close()
    }
}

function Cmd-Capture {
    param([string[]]$Argv)
    $label = ''
    $run = ''
    $json = $false
    $cmd = @()
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--label' {
                if ($i + 1 -ge $Argv.Count) { Die 'capture: --label requires a value' }
                $label = $Argv[$i + 1]; $i += 2
            }
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'capture: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            '--' {
                if ($i + 1 -lt $Argv.Count) {
                    $cmd = @($Argv[($i + 1)..($Argv.Count - 1)])
                } else {
                    $cmd = @()
                }
                $i = $Argv.Count
            }
            default {
                Die "capture: unexpected arg '$($Argv[$i])' (did you forget '--' before the command?)"
            }
        }
    }
    if ([string]::IsNullOrEmpty($label)) { Die 'capture: --label is required' }
    if ($cmd.Count -lt 1 -or [string]::IsNullOrEmpty($cmd[0])) { Die "capture: a command after '--' is required" }
    if (-not (Test-ValidName $label)) { Die "capture: --label must match [A-Za-z0-9._-] and contain no '..'" }

    if ([string]::IsNullOrEmpty($run)) {
        if ($env:AGENT_DONE_SESSION) { $run = $env:AGENT_DONE_SESSION } else { $run = Get-RunStamp }
    }
    if (-not (Test-ValidName $run)) { Die "capture: run id must match [A-Za-z0-9._-] and contain no '..'" }

    $dir = Join-Path $script:PROOF_DIR $run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $log = Join-Path $dir ($label + '.log')

    $rc = Capture-Command -Command $cmd -LogPath $log
    $sha = Get-Sha256OfFile $log
    $now = [DateTime]::UtcNow
    $at = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $epoch = Get-UnixEpoch $now
    $logRel = Get-RelativeLogPath $script:ROOT $log

    $receipt = ('{{"label":"{0}","command":"{1}","exit_code":{2},"sha256":"{3}","log":"{4}","at":"{5}","epoch":{6},"session":"{7}"}}' -f `
        (Json-Escape $label), (Json-Escape (Command-Text $cmd)), $rc, $sha, `
        (Json-Escape $logRel), $at, $epoch, (Json-Escape $env:AGENT_DONE_SESSION))
    Append-TextLine (Join-Path $dir 'ledger.jsonl') $receipt

    $tmp = Join-Path $script:PROOF_DIR ('latest.' + $PID + '.tmp')
    Write-TextFile $tmp ($run + [Environment]::NewLine)
    Move-Item -Force -LiteralPath $tmp -Destination (Join-Path $script:PROOF_DIR 'latest')

    if ($json) { Write-Output $receipt }
    Write-Stderr "done-gate: captured label=$label run=$run exit=$rc sha256=$sha"
    exit $rc
}

function Cmd-Assert {
    param([string[]]$Argv)
    $run = ''
    $ttl = ''
    $regex = ''
    $json = $false
    $labels = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--label' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --label requires a value' }
                [void]$labels.Add($Argv[$i + 1]); $i += 2
            }
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--ttl' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --ttl requires a value' }
                $ttl = $Argv[$i + 1]; $i += 2
            }
            '--allow-command-regex' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --allow-command-regex requires a value' }
                $regex = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "assert: unexpected arg '$($Argv[$i])'"
            }
        }
    }

    if ([string]::IsNullOrEmpty($ttl)) {
        if ($env:AGENT_DONE_TTL) { $ttl = $env:AGENT_DONE_TTL } else { $ttl = '3600' }
    }
    $ttlInt = 3600
    if (-not [int64]::TryParse($ttl, [ref]$ttlInt)) { Die 'assert: --ttl requires an integer value' }
    if ([string]::IsNullOrEmpty($regex) -and $env:AGENT_DONE_ALLOWED_COMMANDS) {
        $regex = $env:AGENT_DONE_ALLOWED_COMMANDS
    }

    $run = Resolve-RunForRead $run $script:PROOF_DIR
    if ([string]::IsNullOrEmpty($run)) {
        if ($json) { Write-Output ('{{"ok":false,"run":"","ttl":{0},"checks":[]}}' -f $ttlInt) }
        Write-Stderr 'done-gate: assert FAIL - no proof run found (capture something first)'
        exit 1
    }
    if (-not (Test-ValidName $run)) { Die 'assert: invalid run id' }
    foreach ($label in $labels) {
        if (-not (Test-ValidName $label)) { Die "assert: --label must match [A-Za-z0-9._-] and contain no '..'" }
    }

    $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) {
        if ($json) { Write-Output ('{{"ok":false,"run":"{0}","ttl":{1},"checks":[]}}' -f (Json-Escape $run), $ttlInt) }
        Write-Stderr "done-gate: assert FAIL - no ledger for run=$run"
        exit 1
    }

    if ($labels.Count -eq 0) {
        $lines = @(Get-Content -LiteralPath $ledger | Where-Object { $_ -ne '' })
        if ($lines.Count -eq 0) {
            if ($json) { Write-Output ('{{"ok":false,"run":"{0}","ttl":{1},"checks":[]}}' -f (Json-Escape $run), $ttlInt) }
            Write-Stderr 'done-gate: assert FAIL - empty ledger'
            exit 1
        }
        $lastLabel = Receipt-Label ([string]$lines[$lines.Count - 1])
        [void]$labels.Add($lastLabel)
    }

    $nowEpoch = Get-UnixEpoch ([DateTime]::UtcNow)
    $overall = 0
    $checks = New-Object System.Collections.ArrayList

    foreach ($label in $labels) {
        $line = Latest-ForLabel $ledger $label
        $found = -not [string]::IsNullOrEmpty($line)
        $exitCode = ''
        $epoch = ''
        $sha = ''
        $cmd = ''
        $fresh = $false
        $commandAllowed = $true
        $ok = $false

        if ($found) {
            $exitCode = Receipt-ExitCode $line
            $epoch = Receipt-Epoch $line
            $sha = Receipt-Sha $line
            $cmd = Receipt-Command $line

            if ($ttlInt -le 0) {
                $fresh = $true
            } elseif ($epoch -match '^[0-9]+$' -and (($nowEpoch - [int64]$epoch) -le $ttlInt)) {
                $fresh = $true
            }

            if (-not [string]::IsNullOrEmpty($regex)) {
                $commandAllowed = ($cmd -match $regex)
            }

            if ($exitCode -eq '0' -and $fresh -and $commandAllowed) { $ok = $true }
        }

        if (-not $ok) { $overall = 1 }

        if ($json) {
            $exitJson = 'null'
            if ($exitCode -match '^[0-9]+$') { $exitJson = $exitCode }
            $checkJson = ('{{"label":"{0}","found":{1},"exit_code":{2},"fresh":{3},"command_allowed":{4},"sha256":"{5}","ok":{6}}}' -f `
                (Json-Escape $label), $found.ToString().ToLowerInvariant(), $exitJson, `
                $fresh.ToString().ToLowerInvariant(), $commandAllowed.ToString().ToLowerInvariant(), `
                (Json-Escape $sha), $ok.ToString().ToLowerInvariant())
            [void]$checks.Add($checkJson)
        } else {
            if ($ok) {
                Write-Stderr "done-gate: assert OK   label=$label exit=$exitCode fresh=$($fresh.ToString().ToLowerInvariant())"
            } else {
                $foundText = if ($found) { 'yes' } else { 'no' }
                $ecText = if ($exitCode) { $exitCode } else { '?' }
                Write-Stderr "done-gate: assert FAIL label=$label found=$foundText exit=$ecText fresh=$($fresh.ToString().ToLowerInvariant()) command_allowed=$($commandAllowed.ToString().ToLowerInvariant())"
            }
        }
    }

    if ($json) {
        $okText = if ($overall -eq 0) { 'true' } else { 'false' }
        Write-Output ('{{"ok":{0},"run":"{1}","ttl":{2},"checks":[{3}]}}' -f $okText, (Json-Escape $run), $ttlInt, ($checks -join ','))
    }
    exit $overall
}

function Cmd-Verify {
    param([string[]]$Argv)
    $label = ''
    $run = ''
    $sha = ''
    $json = $false
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--label' {
                if ($i + 1 -ge $Argv.Count) { Die 'verify: --label requires a value' }
                $label = $Argv[$i + 1]; $i += 2
            }
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'verify: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--sha' {
                if ($i + 1 -ge $Argv.Count) { Die 'verify: --sha requires a value' }
                $sha = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "verify: unexpected arg '$($Argv[$i])'"
            }
        }
    }
    if ([string]::IsNullOrEmpty($label)) { Die 'verify: --label is required' }
    if ([string]::IsNullOrEmpty($sha)) { Die 'verify: --sha is required' }
    if (-not (Test-ValidName $label)) { Die "verify: --label must match [A-Za-z0-9._-] and contain no '..'" }

    $run = Resolve-RunForRead $run $script:PROOF_DIR
    if ([string]::IsNullOrEmpty($run)) { Die 'verify: no run found (run a capture first or pass --run)' }
    if (-not (Test-ValidName $run)) { Die 'verify: invalid run id' }
    $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { Die "verify: no ledger at $ledger" }

    $line = Latest-ForLabel $ledger $label
    $got = ''
    if ($line) { $got = Receipt-Sha $line }
    $expected = $sha.ToLowerInvariant()
    $ok = (-not [string]::IsNullOrEmpty($got)) -and ($got -eq $expected)

    if ($json) {
        Write-Output ('{{"ok":{0},"label":"{1}","run":"{2}","recorded":"{3}","expected":"{4}"}}' -f `
            $ok.ToString().ToLowerInvariant(), (Json-Escape $label), (Json-Escape $run), (Json-Escape $got), (Json-Escape $expected))
    }
    if ($ok) {
        Write-Stderr "done-gate: verify OK label=$label run=$run sha256=$got"
        exit 0
    }
    if ([string]::IsNullOrEmpty($got)) {
        Write-Stderr "done-gate: verify FAIL - no record for label=$label in run=$run"
    } else {
        Write-Stderr "done-gate: verify MISMATCH label=$label run=$run recorded=$got expected=$expected"
    }
    exit 1
}

function Cmd-Show {
    param([string[]]$Argv)
    $run = ''
    $json = $false
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'show: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "show: unexpected arg '$($Argv[$i])'"
            }
        }
    }
    $run = Resolve-RunForRead $run $script:PROOF_DIR
    if ([string]::IsNullOrEmpty($run)) { Die 'show: no run found' }
    if (-not (Test-ValidName $run)) { Die 'show: invalid run id' }
    $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { Die "show: no ledger at $ledger" }

    if ($json) {
        $lines = @(Get-Content -LiteralPath $ledger | Where-Object { $_ -ne '' })
        Write-Output ('{{"run":"{0}","receipts":[{1}]}}' -f (Json-Escape $run), ($lines -join ','))
    } else {
        Write-Output ("# proof ledger {0} run={1}" -f ([char]0x2014), $run)
        Get-Content -LiteralPath $ledger
    }
}

$script:ROOT = Get-Root
$script:PROOF_DIR = if ($env:AGENT_DONE_DIR) { $env:AGENT_DONE_DIR } else { Join-Path $script:ROOT '.agent-proof' }

$argv = @($args)
if ($argv.Count -lt 1) {
    Usage
    exit 2
}

$sub = $argv[0]
$rest = @()
if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }

switch ($sub) {
    'capture' { Cmd-Capture $rest }
    'assert' { Cmd-Assert $rest }
    'verify' { Cmd-Verify $rest }
    'show' { Cmd-Show $rest }
    '-h' { Usage }
    '--help' { Usage }
    'help' { Usage }
    default {
        Usage
        Die "unknown subcommand '$sub' (capture | assert | verify | show)"
    }
}
