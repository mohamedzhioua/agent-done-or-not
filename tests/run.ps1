# tests/run.ps1 - PowerShell parity tests for done-gate.ps1.
# Dependency-free; runs each scenario in a throwaway temp dir. No network.

$ErrorActionPreference = 'Stop'

$PSExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not $PSExe) { $PSExe = 'pwsh' }

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $Here
$DoneGate = Join-Path $Repo 'done-gate.ps1'

$pass = 0
$fail = 0

function Ok {
    param([string]$Name)
    Write-Output "  PASS $Name"
    $script:pass += 1
}

function Bad {
    param([string]$Name)
    Write-Output "  FAIL $Name"
    $script:fail += 1
}

function New-Sandbox {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('agent-done-ps-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Invoke-Gate {
    param(
        [string]$WorkDir,
        [string[]]$Arguments,
        [string]$ProofDir
    )
    if ([string]::IsNullOrEmpty($ProofDir)) {
        $ProofDir = Join-Path $WorkDir '.proof'
    }
    $stdout = Join-Path $WorkDir ('stdout-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $stderr = Join-Path $WorkDir ('stderr-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $oldProof = $env:AGENT_DONE_DIR
    $oldLocation = Get-Location
    try {
        $env:AGENT_DONE_DIR = $ProofDir
        Set-Location $WorkDir
        $_oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $PSExe -NoProfile -File $DoneGate @Arguments 1> $stdout 2> $stderr
            $rc = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $_oldEAP
        }
    } finally {
        Set-Location $oldLocation
        if ($null -eq $oldProof) {
            Remove-Item Env:\AGENT_DONE_DIR -ErrorAction SilentlyContinue
        } else {
            $env:AGENT_DONE_DIR = $oldProof
        }
    }
    $out = ''
    $err = ''
    if (Test-Path -LiteralPath $stdout) { $out = Get-Content -Raw -LiteralPath $stdout }
    if (Test-Path -LiteralPath $stderr) { $err = Get-Content -Raw -LiteralPath $stderr }
    return [pscustomobject]@{
        ExitCode = $rc
        Stdout = $out
        Stderr = $err
        ProofDir = $ProofDir
        WorkDir = $WorkDir
    }
}

function Read-LedgerLines {
    param([string]$ProofDir)
    $latest = (Get-Content -Raw -LiteralPath (Join-Path $ProofDir 'latest')).Trim()
    $ledger = Join-Path (Join-Path $ProofDir $latest) 'ledger.jsonl'
    return ,@(Get-Content -LiteralPath $ledger)
}

function Latest-Receipt {
    param([string]$ProofDir)
    $lines = @(Read-LedgerLines $ProofDir)
    return ($lines[$lines.Count - 1] | ConvertFrom-Json)
}

function PassingCommand {
    return @('pwsh', '-NoProfile', '-Command', 'exit 0')
}

function FailingCommand {
    return @('pwsh', '-NoProfile', '-Command', 'exit 9')
}

Write-Output '== done-gate.ps1 =='

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand))
if ($r.ExitCode -eq 0) { Ok 'capture returns 0 for a passing command' } else { Bad 'capture passing exit' }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (FailingCommand))
if ($r.ExitCode -eq 9) { Ok 'capture propagates a failing exit code' } else { Bad "capture failing exit (got $($r.ExitCode))" }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand))
$receipt = Latest-Receipt $r.ProofDir
if ($receipt.sha256 -match '^[0-9a-f]{64}$' -and $receipt.exit_code -eq 0 -and ([int64]$receipt.epoch) -gt 0) {
    Ok 'ledger records sha256, exit_code and epoch'
} else {
    Bad 'ledger contents'
}

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand))
$sha = (Latest-Receipt $r.ProofDir).sha256
$v = Invoke-Gate $d @('verify', '--label', 't', '--sha', $sha) $r.ProofDir
if ($v.ExitCode -eq 0) { Ok 'verify accepts the matching hash' } else { Bad 'verify match' }

$v = Invoke-Gate $d @('verify', '--label', 't', '--sha', ('0' * 64)) $r.ProofDir
if ($v.ExitCode -eq 1) { Ok 'verify rejects the wrong hash' } else { Bad 'verify mismatch' }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', '../evil', '--') + (PassingCommand))
if ($r.ExitCode -eq 2) { Ok 'rejects a path-unsafe --label' } else { Bad 'label validation' }

$d = New-Sandbox
$r = Invoke-Gate $d @('capture', '--label')
if ($r.ExitCode -eq 2) { Ok 'valueless --label fails with exit 2' } else { Bad 'valueless option' }

Write-Output '== assert =='

$d = New-Sandbox
$r = Invoke-Gate $d @('assert')
if ($r.ExitCode -eq 1) { Ok 'assert fails with no proof' } else { Bad 'assert no-proof' }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand))
$a = Invoke-Gate $d @('assert') $r.ProofDir
if ($a.ExitCode -eq 0) { Ok 'assert passes on a fresh passing receipt' } else { Bad 'assert pass' }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 'test', '--') + (FailingCommand))
$a = Invoke-Gate $d @('assert', '--label', 'test') $r.ProofDir
if ($a.ExitCode -eq 1) { Ok 'assert --label fails on a failing check' } else { Bad 'assert label-fail' }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 'test', '--') + (PassingCommand))
$a = Invoke-Gate $d @('assert', '--label', 'test', '--label', 'build') $r.ProofDir
if ($a.ExitCode -eq 1) { Ok 'assert fails when a required label is missing' } else { Bad 'assert all-labels' }

$d = New-Sandbox
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'rall', '--') + (PassingCommand))
$r2 = Invoke-Gate $d (@('capture', '--label', 'build', '--run', 'rall', '--') + (PassingCommand)) $r1.ProofDir
$a = Invoke-Gate $d @('assert', '--run', 'rall', '--label', 'test', '--label', 'build') $r1.ProofDir
if ($a.ExitCode -eq 0) { Ok 'assert requires and accepts ALL passing labels' } else { Bad 'assert all-labels pass' }

$latest = (Get-Content -Raw -LiteralPath (Join-Path $r1.ProofDir 'latest')).Trim()
$ledger = Join-Path (Join-Path $r1.ProofDir $latest) 'ledger.jsonl'
$old = [int][Math]::Floor((([DateTime]::UtcNow).AddHours(-2) - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds)
$stale = (Get-Content -Raw -LiteralPath $ledger) -replace '"epoch":[0-9]+', ('"epoch":' + $old)
[IO.File]::WriteAllText($ledger, $stale, (New-Object System.Text.UTF8Encoding($false)))
$a = Invoke-Gate $d @('assert', '--label', 'test', '--ttl', '1') $r1.ProofDir
if ($a.ExitCode -eq 1) { Ok 'assert --ttl rejects a stale receipt' } else { Bad 'assert ttl' }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 'test', '--') + (PassingCommand))
$okMatch = Invoke-Gate $d @('assert', '--label', 'test', '--allow-command-regex', '^pwsh -NoProfile -Command exit 0$') $r.ProofDir
$badMatch = Invoke-Gate $d @('assert', '--label', 'test', '--allow-command-regex', '^npm ') $r.ProofDir
if ($okMatch.ExitCode -eq 0 -and $badMatch.ExitCode -eq 1) {
    Ok 'assert --allow-command-regex matches the right command class'
} else {
    Bad "assert regex ($($okMatch.ExitCode)/$($badMatch.ExitCode))"
}

Write-Output '== --json output =='

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--json', '--label', 't', '--') + (PassingCommand))
try {
    $json = $r.Stdout.Trim() | ConvertFrom-Json
    if ($json.label -eq 't' -and $json.exit_code -eq 0 -and $json.sha256) { Ok 'capture --json emits a parseable receipt' } else { Bad 'capture --json fields' }
} catch {
    Bad 'capture --json parse'
}

$a = Invoke-Gate $d @('assert', '--json', '--label', 't') $r.ProofDir
try {
    $json = $a.Stdout.Trim() | ConvertFrom-Json
    if ($json.ok -eq $true -and @($json.checks).Count -eq 1 -and $json.checks[0].label -eq 't') { Ok 'assert --json emits ok=true' } else { Bad 'assert --json fields' }
} catch {
    Bad 'assert --json parse'
}

$sha = (Latest-Receipt $r.ProofDir).sha256
$v = Invoke-Gate $d @('verify', '--json', '--label', 't', '--sha', $sha) $r.ProofDir
try {
    $json = $v.Stdout.Trim() | ConvertFrom-Json
    if ($json.ok -eq $true -and $json.recorded -eq $sha) { Ok 'verify --json emits ok=true on match' } else { Bad 'verify --json fields' }
} catch {
    Bad 'verify --json parse'
}

$s = Invoke-Gate $d @('show', '--json') $r.ProofDir
try {
    $json = $s.Stdout.Trim() | ConvertFrom-Json
    if ($json.run -and @($json.receipts).Count -ge 1 -and @($json.receipts)[0].label -eq 't') { Ok 'show --json emits a receipts array' } else { Bad 'show --json fields' }
} catch {
    Bad 'show --json parse'
}

$a = Invoke-Gate (New-Sandbox) @('assert', '--json')
try {
    $json = $a.Stdout.Trim() | ConvertFrom-Json
    if ($a.ExitCode -eq 1 -and $json.ok -eq $false -and @($json.checks).Count -eq 0) { Ok 'assert --json no-proof emits expected shape' } else { Bad 'assert --json no-proof fields' }
} catch {
    Bad 'assert --json no-proof parse'
}

Write-Output ''
Write-Output ("Result: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -ne 0) { exit 1 }
exit 0
