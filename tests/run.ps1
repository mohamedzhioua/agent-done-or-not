# tests/run.ps1 - PowerShell parity tests for done-gate.ps1.
# Dependency-free; runs each scenario in a throwaway temp dir. No network.

$ErrorActionPreference = 'Stop'

$PSExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not $PSExe) { $PSExe = 'pwsh' }

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $Here
$DoneGate = Join-Path $Repo 'done-gate.ps1'
$StopGate = Join-Path $Repo 'stop-gate.ps1'

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

function Invoke-StopGate {
    param(
        [string]$WorkDir,
        [string]$ProofDir,
        [AllowNull()][string]$Payload = $null
    )
    if ([string]::IsNullOrEmpty($ProofDir)) {
        $ProofDir = Join-Path $WorkDir '.proof'
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PSExe
    $psi.Arguments = '-NoProfile -File "' + $StopGate + '"'
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($PSBoundParameters.ContainsKey('Payload')) {
        $psi.RedirectStandardInput = $true
    }
    $psi.EnvironmentVariables['AGENT_DONE_DIR'] = $ProofDir

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    if ($PSBoundParameters.ContainsKey('Payload')) {
        $p.StandardInput.Write($Payload)
        $p.StandardInput.Close()
    }
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        Stdout = $stdout
        Stderr = $stderr
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
    return @($script:PSExe, '-NoProfile', '-Command', 'exit 0')
}

function FailingCommand {
    return @($script:PSExe, '-NoProfile', '-Command', 'exit 9')
}

# Git-backed sandbox for state-binding tests. Native git writes to stderr under
# some conditions; EAP=Continue keeps WinPS 5.1 from turning that into a throw.
function New-GitSandbox {
    $d = New-Sandbox
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location $d
        & git init -q 2>&1 | Out-Null
        & git config user.email 't@t' 2>&1 | Out-Null
        & git config user.name 't' 2>&1 | Out-Null
        & git commit -q --allow-empty -m init 2>&1 | Out-Null
    } finally {
        Pop-Location
        $ErrorActionPreference = $old
    }
    return $d
}

function Add-GitCommit {
    param([string]$Dir)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location $Dir
        & git commit -q --allow-empty -m next 2>&1 | Out-Null
    } finally {
        Pop-Location
        $ErrorActionPreference = $old
    }
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
$r = Invoke-Gate $d @('capture', '--label', 't', '--', $PSExe, '-NoProfile', '-Command', 'Write-Output "hello"; exit 0')
try {
    $receipt = Latest-Receipt $r.ProofDir
    if ($r.ExitCode -eq 0 -and $receipt.exit_code -eq 0 -and $r.Stdout -match 'hello') {
        Ok 'capture keeps output separate from numeric exit_code'
    } else {
        Bad 'capture output exit_code'
    }
} catch {
    Bad 'capture output ledger parse'
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
$passingRegex = '-NoProfile -Command exit 0$'
$okMatch = Invoke-Gate $d @('assert', '--label', 'test', '--allow-command-regex', $passingRegex) $r.ProofDir
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

Write-Output '== stop-gate.ps1 =='

$d = New-Sandbox
$s = Invoke-StopGate $d (Join-Path $d '.proof')
if ($s.ExitCode -eq 0) { Ok 'stop gate allows when stdin is not piped' } else { Bad "stop gate no-stdin (got $($s.ExitCode))" }

$d = New-Sandbox
$r = Invoke-Gate $d (@('capture', '--label', 'stop', '--') + (PassingCommand))
$payload = '{"session_id":"s1","stop_hook_active":false}'
$s = Invoke-StopGate $d $r.ProofDir $payload
if ($s.ExitCode -eq 0) { Ok 'stop gate allows a fresh passing receipt' } else { Bad "stop gate fresh pass (got $($s.ExitCode))" }

$d = New-Sandbox
$proof = Join-Path $d '.proof'
$run = 'run1'
New-Item -ItemType Directory -Force -Path (Join-Path $proof $run) | Out-Null
[IO.File]::WriteAllText((Join-Path $proof 'latest'), ($run + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$payload = '{"session_id":"s2","stop_hook_active":false}'
$s = Invoke-StopGate $d $proof $payload
if ($s.ExitCode -eq 2) { Ok 'stop gate denies when the ledger is missing' } else { Bad "stop gate missing-ledger (got $($s.ExitCode))" }

Write-Output '== policy + labels =='

# Helper: write a policy file into a sandbox dir
function Write-Policy {
    param(
        [string]$Dir,
        [string]$Content
    )
    $path = Join-Path $Dir 'agent-done.json'
    [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# 1. Policy assert passes when all required labels have fresh passing receipts
#    captured in SEPARATE runs (cross-run global search).
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test"},{"label":"build"}],"ttl":3600}'
$proof = Join-Path $d '.proof'
# Capture test in run1
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
# Capture build in a DIFFERENT run (run2) to exercise cross-run search
$r2 = Invoke-Gate $d (@('capture', '--label', 'build', '--run', 'run2', '--') + (PassingCommand)) $proof
# Assert with the policy file (no --label flags)
$oldPol = $env:AGENT_DONE_POLICY
$env:AGENT_DONE_POLICY = $policy
$a = Invoke-Gate $d @('assert', '--policy', $policy) $proof
if ($null -eq $oldPol) { Remove-Item Env:\AGENT_DONE_POLICY -ErrorAction SilentlyContinue } else { $env:AGENT_DONE_POLICY = $oldPol }
if ($a.ExitCode -eq 0) { Ok 'policy assert passes when all required labels have fresh passing receipts (cross-run)' } else { Bad "policy all-pass (exit $($a.ExitCode)) stderr=$($a.Stderr)" }

# 2. Policy assert fails when a required label is missing
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test"},{"label":"build"}],"ttl":3600}'
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
# No 'build' receipt captured
$a = Invoke-Gate $d @('assert', '--policy', $policy) $proof
if ($a.ExitCode -eq 1) { Ok 'policy assert fails when a required label is missing' } else { Bad "policy missing-label (exit $($a.ExitCode))" }

# 3. Policy assert fails when a required label has a failing receipt
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test"},{"label":"build"}],"ttl":3600}'
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
$r2 = Invoke-Gate $d (@('capture', '--label', 'build', '--run', 'run2', '--') + (FailingCommand)) $proof
$a = Invoke-Gate $d @('assert', '--policy', $policy) $proof
if ($a.ExitCode -eq 1) { Ok 'policy assert fails when a required label has a failing receipt' } else { Bad "policy failed-receipt (exit $($a.ExitCode))" }

# 4. Per-label command_regex from policy - right command passes, wrong fails
$d = New-Sandbox
$hostExePattern = [IO.Path]::GetFileName($PSExe)
$policy = Write-Policy $d ('{"required":[{"label":"test","command_regex":"' + $hostExePattern + '"}],"ttl":3600}')
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
# Right command (PassingCommand starts with the current PowerShell host)
$a = Invoke-Gate $d @('assert', '--policy', $policy) $proof
if ($a.ExitCode -eq 0) { Ok 'policy per-label command_regex passes for matching command' } else { Bad "policy regex-pass (exit $($a.ExitCode)) stderr=$($a.Stderr)" }

$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test","command_regex":"^npm "}],"ttl":3600}'
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
# Wrong command (PassingCommand is pwsh, not npm)
$a = Invoke-Gate $d @('assert', '--policy', $policy) $proof
if ($a.ExitCode -eq 1) { Ok 'policy per-label command_regex fails for non-matching command' } else { Bad "policy regex-fail (exit $($a.ExitCode))" }

# 5. Policy ttl honored - stale receipt fails
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test"}],"ttl":1}'
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
# Backdate the epoch in the ledger
$ledgerPath = Join-Path (Join-Path $proof 'run1') 'ledger.jsonl'
$oldEp = [int][Math]::Floor((([DateTime]::UtcNow).AddHours(-2) - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds)
$content = [System.IO.File]::ReadAllText($ledgerPath)
$content = $content -replace '"epoch":[0-9]+', ('"epoch":' + $oldEp)
[System.IO.File]::WriteAllText($ledgerPath, $content, (New-Object System.Text.UTF8Encoding($false)))
$a = Invoke-Gate $d @('assert', '--policy', $policy) $proof
if ($a.ExitCode -eq 1) { Ok 'policy ttl honored (stale receipt rejected)' } else { Bad "policy ttl (exit $($a.ExitCode))" }

# 6. --no-policy falls back to legacy latest-receipt behavior even when policy file exists
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test"},{"label":"build"}],"ttl":3600}'
$proof = Join-Path $d '.proof'
# Only capture 'test'; policy would require 'build' too - but --no-policy ignores policy
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
$a = Invoke-Gate $d @('assert', '--no-policy') $proof
# Legacy mode: asserts the latest receipt (test), which passes
if ($a.ExitCode -eq 0) { Ok '--no-policy falls back to legacy latest behavior when policy file exists' } else { Bad "--no-policy fallback (exit $($a.ExitCode)) stderr=$($a.Stderr)" }

# 7. Explicit --label still overrides policy (legacy path intact)
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test"},{"label":"build"}],"ttl":3600}'
$proof = Join-Path $d '.proof'
# Only capture 'test'; policy requires 'build' too, but CLI --label overrides
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
$a = Invoke-Gate $d @('assert', '--label', 'test', '--policy', $policy) $proof
if ($a.ExitCode -eq 0) { Ok 'explicit --label overrides policy (legacy path)' } else { Bad "explicit --label override (exit $($a.ExitCode)) stderr=$($a.Stderr)" }

# 8. assert --json includes "policy" key
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test"}],"ttl":3600}'
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
$a = Invoke-Gate $d @('assert', '--json', '--policy', $policy) $proof
try {
    $jobj = $a.Stdout.Trim() | ConvertFrom-Json
    if ($a.ExitCode -eq 0 -and $jobj.PSObject.Properties.Name -contains 'policy' -and $jobj.policy -ne $null) {
        Ok 'assert --json includes "policy" key in policy mode'
    } else {
        Bad "assert --json policy key (ok=$($jobj.ok) policy=$($jobj.policy))"
    }
} catch {
    Bad "assert --json policy key parse: $_"
}

# 9. assert --json "policy" key is "" in legacy/CLI-label mode
$d = New-Sandbox
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand))
$a = Invoke-Gate $d @('assert', '--json', '--label', 'test') $r1.ProofDir
try {
    $jobj = $a.Stdout.Trim() | ConvertFrom-Json
    if ($a.ExitCode -eq 0 -and $jobj.PSObject.Properties.Name -contains 'policy' -and $jobj.policy -eq '') {
        Ok 'assert --json policy key is "" in legacy CLI-label mode'
    } else {
        Bad "assert --json policy empty (ok=$($jobj.ok) policy='$($jobj.policy)')"
    }
} catch {
    Bad "assert --json policy empty parse: $_"
}

# 10. Weak-only (lint) assert prints WARNING but exits 0
$d = New-Sandbox
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'lint', '--run', 'run1', '--') + (PassingCommand)) $proof
$a = Invoke-Gate $d @('assert', '--label', 'lint') $proof
if ($a.ExitCode -eq 0 -and $a.Stderr -match 'WARNING') {
    Ok 'weak-only (lint) assert exits 0 and prints WARNING'
} else {
    Bad "weak-only lint (exit=$($a.ExitCode) stderr=$($a.Stderr))"
}

# 11. SECURITY: a policy present but unparseable (nested brace -> 0 entries) must
#     FAIL CLOSED, never silently fall back to legacy and pass on another label.
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"build","opts":{"x":"y"}}]}'
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
$a = Invoke-Gate $d @('assert', '--policy', $policy) $proof
if ($a.ExitCode -eq 1) { Ok 'policy: unparseable required entry fails closed (no silent legacy PASS)' } else { Bad "policy fail-closed unparseable (exit $($a.ExitCode))" }

# 12. An invalid per-label command_regex fails closed (does not throw; still JSON).
$d = New-Sandbox
$policy = Write-Policy $d '{"required":[{"label":"test","command_regex":"["}]}'
$proof = Join-Path $d '.proof'
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand)) $proof
$a = Invoke-Gate $d @('assert', '--json', '--policy', $policy) $proof
$jsonOk = $false; try { $o = $a.Stdout.Trim() | ConvertFrom-Json; $jsonOk = ($o.ok -eq $false) } catch {}
if ($a.ExitCode -eq 1 -and $jsonOk) { Ok 'policy: invalid command_regex fails closed (no throw, valid JSON)' } else { Bad "policy invalid regex (exit $($a.ExitCode)) jsonOk=$jsonOk" }

# 13. A non-integer --ttl is rejected with exit 2 (parity with the bash engine).
$d = New-Sandbox
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--run', 'run1', '--') + (PassingCommand))
$a = Invoke-Gate $d @('assert', '--label', 'test', '--ttl', 'abc') $r1.ProofDir
if ($a.ExitCode -eq 2) { Ok 'assert --ttl non-integer fails with exit 2' } else { Bad "ttl integer validation (exit $($a.ExitCode))" }

Write-Output '== state binding (v0.9) =='

# 14. capture binds the receipt to git commit + tree + dirty.
$d = New-GitSandbox
$r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand))
$receipt = Latest-Receipt $r.ProofDir
if ($receipt.commit -match '^[0-9a-f]{40}$' -and $receipt.tree -match '^[0-9a-f]{40}$' `
        -and ($receipt.PSObject.Properties.Name -contains 'dirty')) {
    Ok 'capture binds the receipt to commit + tree + dirty'
} else {
    Bad 'state binding: receipt missing commit/tree/dirty'
}

# 15. assert warns on state drift (HEAD advanced) but still exits 0 (advisory).
$d = New-GitSandbox
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--') + (PassingCommand))
Add-GitCommit $d
$a = Invoke-Gate $d @('assert', '--label', 'test') $r1.ProofDir
if ($a.ExitCode -eq 0 -and $a.Stderr -match 'HEAD is now') {
    Ok 'assert warns on state drift (advisory) but exits 0'
} else {
    Bad "assert drift advisory (exit $($a.ExitCode))"
}

# 16. AGENT_DONE_BIND_STATE=1 turns state drift into a hard assert failure.
$d = New-GitSandbox
$r1 = Invoke-Gate $d (@('capture', '--label', 'test', '--') + (PassingCommand))
Add-GitCommit $d
$oldBind = $env:AGENT_DONE_BIND_STATE
$env:AGENT_DONE_BIND_STATE = '1'
try {
    $a = Invoke-Gate $d @('assert', '--label', 'test') $r1.ProofDir
} finally {
    $env:AGENT_DONE_BIND_STATE = $oldBind
}
if ($a.ExitCode -eq 1) { Ok 'AGENT_DONE_BIND_STATE=1 fails assert on drift' } else { Bad "bind-state assert (exit $($a.ExitCode))" }

Write-Output '== stop-gate.ps1 policy + drift (v0.9) =='

$sgPayload = '{"session_id":"s1","stop_hook_active":false}'

# S4. policy-aware: a passing receipt for a NON-required label must not clear the gate.
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
Write-Policy $d '{"required":[{"label":"test"},{"label":"build"}]}' | Out-Null
$null = Invoke-Gate $d (@('capture', '--label', 'lint', '--') + (PassingCommand)) $proof
$s = Invoke-StopGate $d $proof $sgPayload
if ($s.ExitCode -eq 2) { Ok 'stop-gate blocks when a policy label lacks a passing receipt' } else { Bad "stop-gate policy block (got $($s.ExitCode))" }

# S5. policy-aware: allows once every required label has a fresh passing receipt.
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
Write-Policy $d '{"required":[{"label":"test"},{"label":"build"}]}' | Out-Null
$null = Invoke-Gate $d (@('capture', '--label', 'test', '--') + (PassingCommand)) $proof
$null = Invoke-Gate $d (@('capture', '--label', 'build', '--') + (PassingCommand)) $proof
$s = Invoke-StopGate $d $proof $sgPayload
if ($s.ExitCode -eq 0) { Ok 'stop-gate allows when all policy labels are satisfied' } else { Bad "stop-gate policy allow (got $($s.ExitCode))" }

# S6. drift blocks under AGENT_DONE_BIND_STATE=1 (HEAD advanced after capture).
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
$null = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand)) $proof
Add-GitCommit $d
$oldBind = $env:AGENT_DONE_BIND_STATE
$env:AGENT_DONE_BIND_STATE = '1'
try {
    $s = Invoke-StopGate $d $proof $sgPayload
} finally {
    if ($null -eq $oldBind) { Remove-Item Env:AGENT_DONE_BIND_STATE -ErrorAction SilentlyContinue } else { $env:AGENT_DONE_BIND_STATE = $oldBind }
}
if ($s.ExitCode -eq 2) { Ok 'stop-gate blocks on drift when AGENT_DONE_BIND_STATE=1' } else { Bad "stop-gate drift bindstate (got $($s.ExitCode))" }

Write-Output '== receipt provenance (v0.10) =='

function Restore-Env {
    param([string]$Name, [AllowNull()][string]$Value)
    if ($null -eq $Value) { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:$Name" $Value }
}

# 17. a LOCAL capture stamps schema_version:2, ci:false, empty ref. Clear the CI
# env so this passes identically whether the suite runs locally or inside CI.
$d = New-GitSandbox
$oldCI = $env:CI; $oldGA = $env:GITHUB_ACTIONS; $oldRef = $env:GITHUB_REF
Remove-Item Env:CI -ErrorAction SilentlyContinue
Remove-Item Env:GITHUB_ACTIONS -ErrorAction SilentlyContinue
Remove-Item Env:GITHUB_REF -ErrorAction SilentlyContinue
try {
    $r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand))
    $receipt = Latest-Receipt $r.ProofDir
} finally {
    Restore-Env 'CI' $oldCI
    Restore-Env 'GITHUB_ACTIONS' $oldGA
    Restore-Env 'GITHUB_REF' $oldRef
}
if ($receipt.schema_version -eq 2 -and $receipt.ci -eq $false -and $receipt.ref -eq '') {
    Ok 'local capture stamps schema_version:2, ci:false, empty ref'
} else {
    Bad 'provenance: local receipt (schema_version/ci/ref)'
}

# 18. a CI capture (GITHUB_ACTIONS + GITHUB_REF set) stamps ci:true and the ref.
$d = New-GitSandbox
$oldCI = $env:CI; $oldGA = $env:GITHUB_ACTIONS; $oldRef = $env:GITHUB_REF
Remove-Item Env:CI -ErrorAction SilentlyContinue
$env:GITHUB_ACTIONS = 'true'
$env:GITHUB_REF = 'refs/pull/7/merge'
try {
    $r = Invoke-Gate $d (@('capture', '--label', 't', '--') + (PassingCommand))
    $receipt = Latest-Receipt $r.ProofDir
} finally {
    Restore-Env 'CI' $oldCI
    Restore-Env 'GITHUB_ACTIONS' $oldGA
    Restore-Env 'GITHUB_REF' $oldRef
}
if ($receipt.ci -eq $true -and $receipt.ref -eq 'refs/pull/7/merge') {
    Ok 'CI capture stamps ci:true and the ref under test'
} else {
    Bad 'provenance: CI receipt (ci/ref)'
}

Write-Output '== evidence envelope (v0.11) =='

# 19. capture writes the flat v2 envelope with git and producer identity.
$d = New-GitSandbox
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Push-Location $d
    & git remote add origin 'https://example.invalid/project.git' 2>&1 | Out-Null
} finally {
    Pop-Location
    $ErrorActionPreference = $old
}
$r = Invoke-Gate $d (@('capture', '--label', 'envelope', '--') + (PassingCommand))
$receipt = Latest-Receipt $r.ProofDir
if ($receipt.schema_version -eq 2 -and $receipt.disposition -eq 'reexecuted' `
        -and $receipt.producer -eq 'done-gate.ps1@0.13.0' `
        -and $receipt.repo -eq 'https://example.invalid/project.git' `
        -and $receipt.subject -eq 'init' -and -not [string]::IsNullOrEmpty($receipt.host_os)) {
    Ok 'capture writes the v2 evidence envelope with repo, subject and producer'
} else {
    Bad 'evidence envelope fields'
}

# 20. verifier identity is copied from AGENT_DONE_VERIFIER and defaults empty.
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
$oldVerifier = $env:AGENT_DONE_VERIFIER
try {
    $env:AGENT_DONE_VERIFIER = 'x'
    $null = Invoke-Gate $d (@('capture', '--label', 'set', '--run', 'verifier', '--') + (PassingCommand)) $proof
    Remove-Item Env:AGENT_DONE_VERIFIER -ErrorAction SilentlyContinue
    $null = Invoke-Gate $d (@('capture', '--label', 'unset', '--run', 'verifier', '--') + (PassingCommand)) $proof
} finally {
    Restore-Env 'AGENT_DONE_VERIFIER' $oldVerifier
}
$receipts = @(Read-LedgerLines $proof | ForEach-Object { $_ | ConvertFrom-Json })
if ($receipts.Count -eq 2 -and $receipts[0].verifier -eq 'x' -and $receipts[1].verifier -eq '') {
    Ok 'capture records set and unset verifier identity'
} else {
    Bad 'verifier identity'
}

# 21. BACKCOMPAT: a v1 receipt still satisfies assert, verify and stop-gate.
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
$run = 'legacy-v1'
$runDir = Join-Path $proof $run
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$sha = '0' * 64
$now = [int64][Math]::Floor((([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds))
$line = '{"label":"legacy-v1","command":"true","exit_code":0,"sha256":"' + $sha + '","log":"x","at":"2026-07-16T00:00:00Z","epoch":' + $now + ',"session":"","commit":"","tree":"","dirty":true,"schema_version":1,"ci":false,"ref":""}'
[IO.File]::WriteAllText((Join-Path $runDir 'ledger.jsonl'), ($line + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $proof 'latest'), ($run + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$a = Invoke-Gate $d @('assert', '--label', 'legacy-v1') $proof
$v = Invoke-Gate $d @('verify', '--label', 'legacy-v1', '--sha', $sha) $proof
$s = Invoke-StopGate $d $proof '{"session_id":"legacy-v1","stop_hook_active":false}'
if ($a.ExitCode -eq 0 -and $v.ExitCode -eq 0 -and $s.ExitCode -eq 0) {
    Ok 'legacy v1 receipt remains readable by assert, verify and stop-gate'
} else {
    Bad "legacy v1 backcompat ($($a.ExitCode)/$($v.ExitCode)/$($s.ExitCode))"
}

# 22. BACKCOMPAT: a v0 receipt without schema or git fields still works.
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
$run = 'legacy-v0'
$runDir = Join-Path $proof $run
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$now = [int64][Math]::Floor((([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds))
$line = '{"label":"legacy-v0","command":"true","exit_code":0,"sha256":"' + $sha + '","log":"x","at":"2026-07-16T00:00:00Z","epoch":' + $now + ',"session":""}'
[IO.File]::WriteAllText((Join-Path $runDir 'ledger.jsonl'), ($line + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $proof 'latest'), ($run + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$a = Invoke-Gate $d @('assert', '--label', 'legacy-v0') $proof
$v = Invoke-Gate $d @('verify', '--label', 'legacy-v0', '--sha', $sha) $proof
$s = Invoke-StopGate $d $proof '{"session_id":"legacy-v0","stop_hook_active":false}'
if ($a.ExitCode -eq 0 -and $v.ExitCode -eq 0 -and $s.ExitCode -eq 0) {
    Ok 'legacy v0 receipt remains readable by assert, verify and stop-gate'
} else {
    Bad "legacy v0 backcompat ($($a.ExitCode)/$($v.ExitCode)/$($s.ExitCode))"
}

# 23. quotes and backslashes in the commit subject remain valid JSON.
$d = New-GitSandbox
$messageFile = Join-Path (Join-Path $d '.git') 'subject-message.txt'
[IO.File]::WriteAllText($messageFile, 'subject "quoted" \ path', (New-Object System.Text.UTF8Encoding($false)))
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Push-Location $d
    & git commit -q --allow-empty -F $messageFile 2>&1 | Out-Null
} finally {
    Pop-Location
    Remove-Item -LiteralPath $messageFile -ErrorAction SilentlyContinue
    $ErrorActionPreference = $old
}
$r = Invoke-Gate $d (@('capture', '--label', 'subject', '--') + (PassingCommand))
$receipt = Latest-Receipt $r.ProofDir
$a = Invoke-Gate $d @('assert', '--label', 'subject') $r.ProofDir
if ($receipt.subject -eq 'subject "quoted" \ path' -and $a.ExitCode -eq 0) {
    Ok 'quoted commit subject produces parseable evidence'
} else {
    Bad 'commit subject JSON escaping'
}

# 24. SEPARATION: an asserted (disposition!=reexecuted) v2 record is rejected by
# assert, verify AND the stop-gate even though exit_code=0 and it is fresh.
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
$run = 'asserted'
$runDir = Join-Path $proof $run
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$sha = '0' * 64
$now = [int64][Math]::Floor((([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds))
$line = '{"label":"claimed","command":"true","exit_code":0,"sha256":"' + $sha + '","log":"x","at":"2026-07-17T00:00:00Z","epoch":' + $now + ',"session":"","commit":"","tree":"","dirty":false,"schema_version":2,"ci":false,"ref":"","repo":"","subject":"","producer":"x","verifier":"","host_os":"windows","disposition":"asserted"}'
[IO.File]::WriteAllText((Join-Path $runDir 'ledger.jsonl'), ($line + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $proof 'latest'), ($run + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$a = Invoke-Gate $d @('assert', '--label', 'claimed') $proof
$v = Invoke-Gate $d @('verify', '--label', 'claimed', '--sha', $sha) $proof
$s = Invoke-StopGate $d $proof '{"session_id":"asserted","stop_hook_active":false}'
if ($a.ExitCode -ne 0 -and $v.ExitCode -ne 0 -and $s.ExitCode -eq 2) {
    Ok 'asserted (disposition!=reexecuted) receipt is rejected by assert, verify and stop-gate'
} else {
    Bad "disposition enforcement (assert=$($a.ExitCode) verify=$($v.ExitCode) stop=$($s.ExitCode))"
}

# 24b. the guard keys on the disposition field, not a parsed schema_version, so an
# oversized schema_version cannot overflow past the check ([int] would throw/wrap).
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
$run = 'big'
$runDir = Join-Path $proof $run
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$now = [int64][Math]::Floor((([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds))
$line = '{"label":"claimed","command":"true","exit_code":0,"sha256":"' + $sha + '","log":"x","at":"2026-07-17T00:00:00Z","epoch":' + $now + ',"session":"","commit":"","tree":"","dirty":false,"schema_version":9223372036854775808,"ci":false,"ref":"","repo":"","subject":"","producer":"x","verifier":"","host_os":"windows","disposition":"asserted"}'
[IO.File]::WriteAllText((Join-Path $runDir 'ledger.jsonl'), ($line + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $proof 'latest'), ($run + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$a = Invoke-Gate $d @('assert', '--label', 'claimed') $proof
$s = Invoke-StopGate $d $proof '{"session_id":"big","stop_hook_active":false}'
if ($a.ExitCode -ne 0 -and $s.ExitCode -eq 2) {
    Ok 'oversized schema_version cannot smuggle an asserted record past the gate'
} else {
    Bad "disposition guard overflow (assert=$($a.ExitCode) stop=$($s.ExitCode))"
}

# 25. a C0 control byte (form feed) in the commit subject still yields valid JSON.
$d = New-GitSandbox
$messageFile = Join-Path (Join-Path $d '.git') 'ff-message.txt'
[IO.File]::WriteAllText($messageFile, "subject`fform", (New-Object System.Text.UTF8Encoding($false)))
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Push-Location $d
    & git commit -q --allow-empty -F $messageFile 2>&1 | Out-Null
} finally {
    Pop-Location
    Remove-Item -LiteralPath $messageFile -ErrorAction SilentlyContinue
    $ErrorActionPreference = $old
}
$r = Invoke-Gate $d (@('capture', '--label', 'ff', '--') + (PassingCommand))
try {
    $receipt = Latest-Receipt $r.ProofDir
    $hasControl = $false
    foreach ($ch in $receipt.subject.ToCharArray()) { if ([int]$ch -lt 0x20) { $hasControl = $true } }
    if (-not $hasControl -and $receipt.subject -match 'form') {
        Ok 'control character in commit subject produces parseable JSON'
    } else {
        Bad "control-char JSON escaping (subject=$($receipt.subject))"
    }
} catch {
    Bad 'control-char JSON escaping (receipt did not parse as JSON)'
}

# 26. host_os is a canonical, engine-portable value (never a raw uname). This
# suite runs under pwsh on Windows, Linux and macOS, so assert membership in the
# shared vocabulary rather than a single OS — mirrors done-gate.sh's EV9.
$d = New-GitSandbox
$r = Invoke-Gate $d (@('capture', '--label', 'os', '--') + (PassingCommand))
$receipt = Latest-Receipt $r.ProofDir
if (@('linux', 'darwin', 'windows') -contains $receipt.host_os) {
    Ok 'host_os is a canonical, engine-portable value'
} else {
    Bad "host_os canonicalization (got $($receipt.host_os))"
}

Write-Output '== claim audit (v0.12) =='

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# a sandbox with test(pass), lint(fail), build(pass) captured into ONE run
function New-AuditSandbox {
    $d = New-GitSandbox
    $proof = Join-Path $d '.proof'
    $null = Invoke-Gate $d (@('capture', '--run', 'myrun', '--label', 'test', '--') + (PassingCommand)) $proof
    $null = Invoke-Gate $d (@('capture', '--run', 'myrun', '--label', 'lint', '--') + (FailingCommand)) $proof
    $null = Invoke-Gate $d (@('capture', '--run', 'myrun', '--label', 'build', '--') + (PassingCommand)) $proof
    return [pscustomobject]@{ Dir = $d; Proof = $proof }
}

function Invoke-SubagentAudit {
    param([string]$WorkDir, [string]$ProofDir, [string]$Payload)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PSExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Repo 'subagent-audit.ps1') + '"'
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['AGENT_DONE_DIR'] = $ProofDir
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $p.StandardInput.Write($Payload)
    $p.StandardInput.Close()
    $null = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $p.ExitCode
}

# 27. marker verdicts (BACKED / MISREPORTED / UNBACKED / INTEGRITY_MISMATCH) and a
# non-zero exit — asserted via --json (byte-identical to bash; human em dash is a
# pre-existing PS 5.1 console-encoding quirk shared with `show`).
$s = New-AuditSandbox
$lines = @(Read-LedgerLines $s.Proof)
$testLine = $lines | Where-Object { $_ -match '"label":"test"' } | Select-Object -First 1
$tsha = ([regex]::Match($testLine, '"sha256":"([0-9a-f]+)"')).Groups[1].Value
$summary = Join-Path $s.Dir 'summary.md'
$md = '<agent-done:claim label="test" exit="0" sha256="' + $tsha + '" />' + "`n" +
      '<agent-done:claim label="lint" exit="0" />' + "`n" +
      '<agent-done:claim label="integration" exit="0" />' + "`n" +
      '<agent-done:claim label="build" exit="0" sha256="deadbeef" />' + "`n"
[IO.File]::WriteAllText($summary, $md, $Utf8NoBom)
$a = Invoke-Gate $s.Dir @('audit', '--transcript', $summary, '--run', 'myrun', '--json') $s.Proof
try {
    $j = $a.Stdout | ConvertFrom-Json
    $v = @{}
    foreach ($c in $j.claims) { $v[$c.label] = $c.verdict }
    if ($v['test'] -eq 'BACKED' -and $v['lint'] -eq 'MISREPORTED' -and $v['integration'] -eq 'UNBACKED' `
            -and $v['build'] -eq 'INTEGRITY_MISMATCH' -and $j.ok -eq $false -and $a.ExitCode -eq 1) {
        Ok 'audit marker verdicts (backed/misreported/unbacked/integrity) + non-zero exit'
    } else {
        Bad "audit marker verdicts (exit=$($a.ExitCode)) out=$($a.Stdout)"
    }
} catch {
    Bad "audit marker verdicts did not produce parseable JSON: $($a.Stdout)"
}

# 28. every claim backed -> exit 0.
$s = New-AuditSandbox
$okmd = Join-Path $s.Dir 'ok.md'
[IO.File]::WriteAllText($okmd, '<agent-done:claim label="test" exit="0" />' + "`n" + '<agent-done:claim label="build" exit="0" />' + "`n", $Utf8NoBom)
$a = Invoke-Gate $s.Dir @('audit', '--transcript', $okmd, '--run', 'myrun') $s.Proof
if ($a.ExitCode -eq 0) { Ok 'audit exits 0 when every claim is backed' } else { Bad "audit all-backed exit ($($a.ExitCode))" }

# 29. SubagentStop hook: blocks unbacked (2), allows backed (0), fails open on an
# ambiguous payload and on the loop guard.
$s = New-AuditSandbox
$tbad = Join-Path $s.Dir 't_bad'
$tgood = Join-Path $s.Dir 't_good'
[IO.File]::WriteAllText($tbad, 'report <agent-done:claim label="integration" exit="0" />' + "`n", $Utf8NoBom)
[IO.File]::WriteAllText($tgood, 'report <agent-done:claim label="test" exit="0" />' + "`n", $Utf8NoBom)
$pbad = ($tbad -replace '\\', '/')
$pgood = ($tgood -replace '\\', '/')
$block = Invoke-SubagentAudit $s.Dir $s.Proof ('{"session_id":"s","stop_hook_active":false,"transcript_path":"' + $pbad + '"}')
$allow = Invoke-SubagentAudit $s.Dir $s.Proof ('{"session_id":"s","stop_hook_active":false,"transcript_path":"' + $pgood + '"}')
$amb = Invoke-SubagentAudit $s.Dir $s.Proof '{"session_id":"s","stop_hook_active":false}'
$loop = Invoke-SubagentAudit $s.Dir $s.Proof ('{"session_id":"s","stop_hook_active":true,"transcript_path":"' + $pbad + '"}')
if ($block -eq 2 -and $allow -eq 0 -and $amb -eq 0 -and $loop -eq 0) {
    Ok 'subagent-audit.ps1 blocks unbacked, allows backed, fails open on ambiguity/loop'
} else {
    Bad "subagent-audit.ps1 hook (block=$block allow=$allow amb=$amb loop=$loop)"
}

# 30. audit rejects a missing --transcript with exit 2.
$d = New-GitSandbox
$a = Invoke-Gate $d @('audit')
if ($a.ExitCode -eq 2) { Ok 'audit requires --transcript (exit 2)' } else { Bad "audit usage guard ($($a.ExitCode))" }

# 31. a zero-looking-but-not-"0" / garbage claimed exit on a FAILING check must
# still be MISREPORTED — cannot be laundered into BACKED (mirrors bash A9).
$s = New-AuditSandbox
$bad31 = $false
foreach ($e in @('00', ' 0', 'fail')) {
    $md = Join-Path $s.Dir 'e.md'
    [IO.File]::WriteAllText($md, ('<agent-done:claim label="lint" exit="' + $e + '" />' + "`n"), $Utf8NoBom)
    $a = Invoke-Gate $s.Dir @('audit', '--transcript', $md, '--run', 'myrun', '--json') $s.Proof
    try { $vv = ($a.Stdout | ConvertFrom-Json).claims[0].verdict } catch { $vv = 'ERR' }
    if ($vv -ne 'MISREPORTED') { $bad31 = $true }
}
$md = Join-Path $s.Dir 'e.md'
[IO.File]::WriteAllText($md, '<agent-done:claim label="lint" exit="1" />' + "`n", $Utf8NoBom)
$a = Invoke-Gate $s.Dir @('audit', '--transcript', $md, '--run', 'myrun', '--json') $s.Proof
try { $vv1 = ($a.Stdout | ConvertFrom-Json).claims[0].verdict } catch { $vv1 = 'ERR' }
if (-not $bad31 -and $vv1 -eq 'BACKED') {
    Ok 'a crafted claimed exit cannot launder a failing check into BACKED'
} else {
    Bad "audit misreported normalization (00/ 0/fail bad=$bad31, exit1=$vv1)"
}

# 32. the heuristic binds labels on a WHOLE token only (mirrors bash A10).
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
$null = Invoke-Gate $d (@('capture', '--run', 'wb', '--label', 'test', '--') + (FailingCommand)) $proof
$pmd = Join-Path $d 'p.md'
[IO.File]::WriteAllText($pmd, 'This is the greatest refactor, all verified and shipped.' + "`n", $Utf8NoBom)
$a = Invoke-Gate $d @('audit', '--transcript', $pmd, '--run', 'wb', '--json') $proof
try {
    $j = $a.Stdout | ConvertFrom-Json
    $boundTest = @($j.claims | Where-Object { $_.label -eq 'test' }).Count
    if ($j.ok -eq $true -and $boundTest -eq 0) {
        Ok 'heuristic binds whole-token labels only (no substring false positive)'
    } else {
        Bad "audit substring binding (ok=$($j.ok) boundTest=$boundTest)"
    }
} catch {
    Bad "audit substring binding did not parse: $($a.Stdout)"
}

Write-Output '== PR Receipts / review-pr (v0.13) =='

$npm = [bool](Get-Command npm -ErrorAction SilentlyContinue)

# 33. Node project: passing test + failing lint are RE-EXECUTED; build (no script)
# + "no breaking changes" ASSERTED; vague phrase UNPARSED; failed re-run -> exit 1.
if ($npm) {
    $d = New-GitSandbox
    $proof = Join-Path $d '.proof'
    [IO.File]::WriteAllText((Join-Path $d 'package.json'), '{"name":"demo","version":"1.0.0","scripts":{"test":"node -e \"process.exit(0)\"","lint":"node -e \"process.exit(1)\""}}', $Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $d 'pr.md'), "Tests pass and lint is clean. The build succeeds.`nNo breaking changes. Should be good to merge now.`n", $Utf8NoBom)
    $a = Invoke-Gate $d @('review-pr', '--body', (Join-Path $d 'pr.md'), '--json') $proof
    try {
        $j = $a.Stdout | ConvertFrom-Json
        $tp = @($j.reexecuted | Where-Object { $_.command -eq 'npm test' })[0]
        $lc = @($j.reexecuted | Where-Object { $_.command -eq 'npm run lint' })[0]
        if ($j.summary.reexecuted -eq 2 -and $tp.status -eq 'pass' -and $tp.exit_code -eq 0 `
                -and $lc.status -eq 'fail' -and $lc.exit_code -ne 0 `
                -and $j.summary.asserted -ge 2 -and $j.summary.unparsed -ge 1 `
                -and $j.ok -eq $false -and $a.ExitCode -eq 1) {
            Ok 'review-pr re-executes Node claims (pass+fail), asserts + unparses, exits non-zero'
        } else { Bad "review-pr Node (exit=$($a.ExitCode)): $($a.Stdout)" }
    } catch { Bad "review-pr Node did not parse: $($a.Stdout)" }
} else { Ok 'review-pr Node test skipped (no npm on PATH)' }

# 34. command resolution per ecosystem — assert the resolved command string,
# independent of whether the toolchain is installed.
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
[IO.File]::WriteAllText((Join-Path $d 'pyproject.toml'), "[project]`nname = `"x`"`n", $Utf8NoBom)
[IO.File]::WriteAllText((Join-Path $d 'pr.md'), "Tests pass.`n", $Utf8NoBom)
$a = Invoke-Gate $d @('review-pr', '--body', (Join-Path $d 'pr.md'), '--json') $proof
$d2 = New-GitSandbox
$proof2 = Join-Path $d2 '.proof'
[IO.File]::WriteAllText((Join-Path $d2 'go.mod'), "module x`n`ngo 1.20`n", $Utf8NoBom)
[IO.File]::WriteAllText((Join-Path $d2 'pr.md'), "Tests pass.`n", $Utf8NoBom)
$a2 = Invoke-Gate $d2 @('review-pr', '--body', (Join-Path $d2 'pr.md'), '--json') $proof2
try {
    $cpy = ($a.Stdout | ConvertFrom-Json).reexecuted[0].command
    $cgo = ($a2.Stdout | ConvertFrom-Json).reexecuted[0].command
    if ($cpy -eq 'pytest' -and $cgo -eq 'go test ./...') {
        Ok 'review-pr resolves the real command per ecosystem (pytest / go test)'
    } else { Bad "review-pr command resolution (py=$cpy go=$cgo)" }
} catch { Bad "review-pr resolution did not parse" }

# 35. SECURITY: a claim line cannot inject a command — the re-run stays the
# manifest-resolved command, and nothing embedded in the PR text runs.
if ($npm) {
    $d = New-GitSandbox
    $proof = Join-Path $d '.proof'
    [IO.File]::WriteAllText((Join-Path $d 'package.json'), '{"name":"demo","version":"1.0.0","scripts":{"test":"node -e \"process.exit(0)\""}}', $Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $d 'pr.md'), "tests pass & echo pwned > PWNED`n", $Utf8NoBom)
    $a = Invoke-Gate $d @('review-pr', '--body', (Join-Path $d 'pr.md'), '--json') $proof
    try {
        $cmd = ($a.Stdout | ConvertFrom-Json).reexecuted[0].command
        if ($cmd -eq 'npm test' -and -not (Test-Path -LiteralPath (Join-Path $d 'PWNED'))) {
            Ok 'review-pr does not execute commands embedded in PR text (no injection)'
        } else { Bad "review-pr injection (cmd=$cmd pwned=$(Test-Path (Join-Path $d 'PWNED')))" }
    } catch { Bad "review-pr injection did not parse: $($a.Stdout)" }
} else { Ok 'review-pr injection test skipped (no npm on PATH)' }

# 36. review-pr rejects a missing --body with exit 2.
$d = New-GitSandbox
$a = Invoke-Gate $d @('review-pr')
if ($a.ExitCode -eq 2) { Ok 'review-pr requires --body (exit 2)' } else { Bad "review-pr usage guard ($($a.ExitCode))" }

# 37. the receipt never says VERIFIED (label discipline).
$d = New-GitSandbox
$proof = Join-Path $d '.proof'
[IO.File]::WriteAllText((Join-Path $d 'pr.md'), "Tests pass. No breaking changes. Should be good.`n", $Utf8NoBom)
$a = Invoke-Gate $d @('review-pr', '--body', (Join-Path $d 'pr.md')) $proof
$txt = $a.Stdout + "`n" + $a.Stderr
if ($txt -match 'RE-EXECUTED|ASSERTED|UNPARSED' -and $txt -notmatch '(?i)verified') {
    Ok 'review-pr uses RE-EXECUTED/ASSERTED/UNPARSED, never VERIFIED'
} else { Bad 'review-pr label discipline' }

# 38. the per-command timeout bounds a hanging re-run, reports exit 124, and stays
# valid JSON (regression for the WaitForExit Boolean leak).
if ($npm) {
    $d = New-GitSandbox
    $proof = Join-Path $d '.proof'
    [IO.File]::WriteAllText((Join-Path $d 'package.json'), '{"name":"demo","version":"1.0.0","scripts":{"test":"node -e \"setTimeout(function(){},8000)\""}}', $Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $d 'pr.md'), "Tests pass.`n", $Utf8NoBom)
    $old = $env:AGENT_DONE_PR_TIMEOUT
    try {
        $env:AGENT_DONE_PR_TIMEOUT = '1'
        $a = Invoke-Gate $d @('review-pr', '--body', (Join-Path $d 'pr.md'), '--json') $proof
    } finally {
        if ($null -eq $old) { Remove-Item Env:\AGENT_DONE_PR_TIMEOUT -ErrorAction SilentlyContinue } else { $env:AGENT_DONE_PR_TIMEOUT = $old }
    }
    try {
        $c = ($a.Stdout | ConvertFrom-Json).reexecuted[0]
        if ($c.exit_code -eq 124 -and $c.status -eq 'fail') {
            Ok 'review-pr bounds a hanging re-run with a timeout (exit 124, valid JSON)'
        } else { Bad "review-pr timeout (exit_code=$($c.exit_code) status=$($c.status))" }
    } catch { Bad "review-pr timeout produced invalid JSON: $($a.Stdout)" }
} else { Ok 'review-pr timeout test skipped (no npm)' }

Write-Output ''
Write-Output ("Result: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -ne 0) { exit 1 }
exit 0
