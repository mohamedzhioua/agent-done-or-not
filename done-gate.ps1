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
  assert  [--label L ...] [--run R] [--ttl S] [--allow-command-regex RE] [--policy FILE] [--no-policy] [--json]
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

function Resolve-PolicyPath {
    param(
        [AllowNull()][string]$Explicit,
        [string]$Root
    )
    if (-not [string]::IsNullOrEmpty($Explicit)) { return $Explicit }
    if ($env:AGENT_DONE_POLICY) { return $env:AGENT_DONE_POLICY }
    $def = Join-Path $Root 'agent-done.json'
    if (Test-Path -LiteralPath $def) { return $def }
    return ''
}

# Emit one PSCustomObject per required entry with Label and Regex properties.
function Get-PolicyEntries {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    $raw = [System.IO.File]::ReadAllText($File, (Get-Utf8NoBom))
    # Flatten newlines as per spec
    $flat = $raw -replace "`r`n|`r|`n", ' '
    $entries = New-Object System.Collections.ArrayList
    $objMatches = [regex]::Matches($flat, '\{[^{}]*\}')
    foreach ($m in $objMatches) {
        $obj = $m.Value
        $labelM = [regex]::Match($obj, '"label"\s*:\s*"([^"]*)"')
        if (-not $labelM.Success) { continue }
        $lbl = $labelM.Groups[1].Value
        $rxM = [regex]::Match($obj, '"command_regex"\s*:\s*"([^"]*)"')
        $rx = if ($rxM.Success) { $rxM.Groups[1].Value } else { '' }
        [void]$entries.Add([pscustomobject]@{ Label = $lbl; Regex = $rx })
    }
    return @($entries)
}

# Top-level "ttl" integer from the policy file, or empty string.
function Get-PolicyTtl {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    $raw = [System.IO.File]::ReadAllText($File, (Get-Utf8NoBom))
    $flat = $raw -replace "`r`n|`r|`n", ' '
    $m = [regex]::Match($flat, '"ttl"\s*:\s*([0-9]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Label strength taxonomy
function Test-LabelWeak {
    param([string]$Label)
    return ($Label -in @('lint','format','fmt','style','manual','docs'))
}

# Most recent receipt for a label across ALL run dirs (highest epoch), or ''.
function Latest-ForLabelGlobal {
    param(
        [string]$ProofDir,
        [string]$Label
    )
    $needle = '"label":"' + (Json-Escape $Label) + '"'
    $bestEp = [int64]-1
    $best = ''
    foreach ($ledgerPath in (Get-ChildItem -Path $ProofDir -Recurse -Filter 'ledger.jsonl' -ErrorAction SilentlyContinue)) {
        $lines = @(Get-Content -LiteralPath $ledgerPath.FullName | Where-Object { $_.Contains($needle) })
        if ($lines.Count -eq 0) { continue }
        $line = [string]$lines[$lines.Count - 1]
        $epStr = (Rec-Field $line '"epoch":([0-9]+)')
        $ep = if ($epStr -match '^[0-9]+$') { [int64]$epStr } else { [int64]0 }
        if ($ep -gt $bestEp) { $bestEp = $ep; $best = $line }
    }
    return $best
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
    $policyFlag = ''
    $noPolicy = $false
    $labels = New-Object System.Collections.ArrayList
    $labelRegexes = New-Object System.Collections.ArrayList
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
            '--policy' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --policy requires a value' }
                $policyFlag = $Argv[$i + 1]; $i += 2
            }
            '--no-policy' {
                $noPolicy = $true; $i += 1
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "assert: unexpected arg '$($Argv[$i])'"
            }
        }
    }

    if ([string]::IsNullOrEmpty($regex) -and $env:AGENT_DONE_ALLOWED_COMMANDS) {
        $regex = $env:AGENT_DONE_ALLOWED_COMMANDS
    }

    # Resolution order: explicit CLI --label (legacy) > policy file > latest receipt.
    $policyUsed = ''
    $policyMode = $false

    if ($labels.Count -gt 0) {
        # Legacy CLI-label path: per-label regex = global --allow-command-regex
        foreach ($_ in $labels) { [void]$labelRegexes.Add($regex) }
    } elseif (-not $noPolicy) {
        $policyPath = Resolve-PolicyPath $policyFlag $script:ROOT
        if (-not [string]::IsNullOrEmpty($policyPath) -and (Test-Path -LiteralPath $policyPath)) {
            # Compute relative path for policyUsed (mirror bash: strip ROOT/ prefix)
            $rootFull = [IO.Path]::GetFullPath($script:ROOT).TrimEnd('\','/')
            $polFull  = [IO.Path]::GetFullPath($policyPath)
            $prefix1  = $rootFull + [IO.Path]::DirectorySeparatorChar
            $prefix2  = $rootFull + [IO.Path]::AltDirectorySeparatorChar
            if ($polFull.StartsWith($prefix1, [StringComparison]::OrdinalIgnoreCase)) {
                $policyUsed = ($polFull.Substring($prefix1.Length)) -replace '\\','/'
            } elseif ($polFull.StartsWith($prefix2, [StringComparison]::OrdinalIgnoreCase)) {
                $policyUsed = ($polFull.Substring($prefix2.Length)) -replace '\\','/'
            } else {
                $policyUsed = $policyPath -replace '\\','/'
            }

            $entries = @(Get-PolicyEntries $policyPath)
            foreach ($entry in $entries) {
                if ([string]::IsNullOrEmpty($entry.Label)) { continue }
                [void]$labels.Add($entry.Label)
                $entryRx = if (-not [string]::IsNullOrEmpty($entry.Regex)) { $entry.Regex } else { $regex }
                [void]$labelRegexes.Add($entryRx)
            }
            # Policy present but no parseable "required" entries — FAIL CLOSED
            # instead of silently degrading to latest-receipt (a policy that says
            # "do more" must never quietly do less).
            if ($labels.Count -eq 0) {
                if ($json) { Write-Output ('{{"ok":false,"reason":"policy present but no parseable required entries","policy":"{0}","checks":[]}}' -f (Json-Escape $policyUsed)) }
                Write-Stderr ('done-gate: assert FAIL — policy {0} present but no parseable "required" entries (check for nested braces / quoting)' -f $policyUsed)
                exit 1
            }
            $policyMode = $true
            if ([string]::IsNullOrEmpty($ttl)) {
                $pttl = Get-PolicyTtl $policyPath
                if (-not [string]::IsNullOrEmpty($pttl)) { $ttl = $pttl }
            }
        }
    }

    if ([string]::IsNullOrEmpty($ttl)) {
        if ($env:AGENT_DONE_TTL) { $ttl = $env:AGENT_DONE_TTL } else { $ttl = '3600' }
    }
    # Validate as a non-negative integer (mirror bash) so identical input yields
    # identical exit/JSON across engines.
    if ($ttl -notmatch '^[0-9]+$') { Die 'assert: --ttl must be a non-negative integer' }
    $ttlInt = [int64]$ttl

    # Run-scoped modes need a resolved run + ledger. Policy mode searches all runs.
    $ledger = ''
    $runLabel = $run

    if ($policyMode) {
        $runLabel = '*'
        $anyLedger = @(Get-ChildItem -Path $script:PROOF_DIR -Recurse -Filter 'ledger.jsonl' -ErrorAction SilentlyContinue)
        if ($anyLedger.Count -eq 0) {
            if ($json) { Write-Output ('{{"ok":false,"reason":"no proof receipts found","policy":"{0}","checks":[]}}' -f (Json-Escape $policyUsed)) }
            Write-Stderr 'done-gate: assert FAIL — no proof receipts found (capture something first)'
            exit 1
        }
    } else {
        $run = Resolve-RunForRead $run $script:PROOF_DIR
        if ([string]::IsNullOrEmpty($run)) {
            if ($json) { Write-Output ('{{"ok":false,"reason":"no proof run found","policy":"{0}","checks":[]}}' -f (Json-Escape $policyUsed)) }
            Write-Stderr 'done-gate: assert FAIL — no proof run found (capture something first)'
            exit 1
        }
        if (-not (Test-ValidName $run)) { Die 'assert: invalid run id' }
        $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
        $runLabel = $run
        if (-not (Test-Path -LiteralPath $ledger)) {
            if ($json) { Write-Output ('{{"ok":false,"reason":"ledger missing","run":"{0}","policy":"{1}","checks":[]}}' -f (Json-Escape $run), (Json-Escape $policyUsed)) }
            Write-Stderr "done-gate: assert FAIL — no ledger for run=$run"
            exit 1
        }

        # With no explicit/policy labels, assert against the most recent receipt.
        if ($labels.Count -eq 0) {
            $lines = @(Get-Content -LiteralPath $ledger | Where-Object { $_ -ne '' })
            if ($lines.Count -eq 0) {
                if ($json) { Write-Output ('{{"ok":false,"run":"{0}","ttl":{1},"policy":"{2}","checks":[]}}' -f (Json-Escape $run), $ttlInt, (Json-Escape $policyUsed)) }
                Write-Stderr 'done-gate: assert FAIL — empty ledger'
                exit 1
            }
            $lastLabel = Receipt-Label ([string]$lines[$lines.Count - 1])
            [void]$labels.Add($lastLabel)
            [void]$labelRegexes.Add($regex)
        }
    }

    $nowEpoch = Get-UnixEpoch ([DateTime]::UtcNow)
    $overall = 0
    $checks = New-Object System.Collections.ArrayList
    $anyPass = $false
    $weakOnly = $true
    $warnLabel = ''

    for ($idx = 0; $idx -lt $labels.Count; $idx++) {
        $label = [string]$labels[$idx]
        $lrx = if ($idx -lt $labelRegexes.Count) { [string]$labelRegexes[$idx] } else { '' }

        if ($policyMode) {
            $line = Latest-ForLabelGlobal $script:PROOF_DIR $label
        } else {
            $line = Latest-ForLabel $ledger $label
        }

        $found = -not [string]::IsNullOrEmpty($line)
        $exitCode = ''
        $epochStr = ''
        $sha = ''
        $cmd = ''
        $fresh = $false
        $commandAllowed = $true
        $ok = $false

        if ($found) {
            $exitCode = Receipt-ExitCode $line
            $epochStr = Receipt-Epoch $line
            $sha = Receipt-Sha $line
            $cmd = Receipt-Command $line

            if ($ttlInt -le 0) {
                $fresh = $true
            } elseif ($epochStr -match '^[0-9]+$' -and (($nowEpoch - [int64]$epochStr) -le $ttlInt)) {
                $fresh = $true
            }

            if (-not [string]::IsNullOrEmpty($lrx)) {
                # An invalid regex must fail closed (not throw), mirroring bash's
                # `grep -Eq ... 2>/dev/null` which treats a bad pattern as no-match.
                try { $commandAllowed = ($cmd -match $lrx) } catch { $commandAllowed = $false }
            }

            if ($exitCode -eq '0' -and $fresh -and $commandAllowed) { $ok = $true }
        }

        if (-not $ok) { $overall = 1 }

        # Advisory wrong-check bookkeeping (never affects exit code)
        if ($ok) {
            $anyPass = $true
            if (Test-LabelWeak $label) { $warnLabel = $label } else { $weakOnly = $false }
        }

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
        Write-Output ('{{"ok":{0},"run":"{1}","ttl":{2},"policy":"{3}","checks":[{4}]}}' -f `
            $okText, (Json-Escape $runLabel), $ttlInt, (Json-Escape $policyUsed), ($checks -join ','))
    } elseif ($anyPass -and $weakOnly) {
        Write-Stderr "done-gate: WARNING — latest proof is $warnLabel-only — this may not verify the requested behavior"
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
