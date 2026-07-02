---
name: done-or-not
description: >
  Proof-of-done enforcement gate — records fresh evidence before any agent can
  claim "done". Runs your verifying command
  (tests, build, lint, curl) through a tamper-evident gate that records the
  command, exit code, and SHA-256 of the output. Blocks completion on any
  failing, stale, or already-consumed receipt. Works with Claude Code (hard
  Stop-hook enforcement), Cursor, Codex, Windsurf, Cline, Roo, Zed, Goose,
  and any harness that supports stop/finish hooks.
license: MIT
keywords:
  - proof
  - verification
  - enforcement
  - gate
  - done
  - trust
  - anti-hallucination
  - tamper-evident
  - sha256
  - receipt
  - ci
  - testing
  - pre-commit
  - stop-hook
  - agent
  - claude-code
  - cursor
  - codex
  - windsurf
  - cline
  - roo
metadata:
  author: mohamedzhioua
  version: "0.9.0"
---

# done-or-not

## Why this exists

AI agents routinely announce tasks are complete without verifying anything
actually ran. This skill enforces a **proof gate**: the agent must run the real
check (tests, build, typecheck, lint, a `curl` against the endpoint — whatever
demonstrates the claim), record a tamper-evident receipt, and only then may it
report done.

The gate records: the command, its exit code, and a SHA-256 of its full
output. Freshness is judged by the epoch *inside* the receipt (not file mtime,
which `touch` could forge). A receipt can only clear one stop — it is consumed
on use.

## When to use

Use whenever you are about to tell the user that a task, build, test, fix, or
verification step is finished. A completion claim requires proof from the gate,
not confidence or memory.

## How to use

### Portable skill command

1. Identify the command that verifies the work. Choose the smallest check that
   actually verifies the claim: tests, build, typecheck, lint, a `curl` against
   a running endpoint, or another command with meaningful pass/fail behavior.

2. Run the verifying command through the proof gate. This works even when this
   skill was installed without the repo-root gate scripts:

   ```bash
   npx agent-done-or-not capture --label check -- <your verifying command>
   ```

   If the protected repo was initialized with local scripts, these faster local
   forms are also valid:

   ```bash
   bash done-gate.sh capture --label check -- <your verifying command>
   pwsh -File done-gate.ps1 capture --label check -- <your verifying command>
   ```

   The gate records the command, its exit code, and a SHA-256 of the output.
   It exits with the command's own code, so a failing check fails the capture.

3. Only report the work complete after a fresh PASSING receipt exists.

4. If the check fails, fix the problem and capture again. Never report success
   on a red check.

### Windows (native PowerShell — no bash required)

```powershell
npx agent-done-or-not capture --label check -- <your verifying command>
pwsh -File done-gate.ps1 capture --label check -- <your verifying command>
# or, on Windows PowerShell 5.1:
powershell -NoProfile -File done-gate.ps1 capture --label check -- <your verifying command>
```

## Hard enforcement

The Stop gate enforces this rule where the harness supports it: it blocks the
agent from ending the turn until a fresh passing receipt exists. Do not work
around the gate; produce the proof.

Wire the hard stop hook in Claude Code (`settings.json`):

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"$CLAUDE_PROJECT_DIR/stop-gate.sh\""
      }]
    }]
  }
}
```

On Windows, replace with:
```json
"command": "powershell -NoProfile -File \"$env:CLAUDE_PROJECT_DIR\\stop-gate.ps1\""
```

No repo-root scripts? Wire the hook straight through npx instead — it pipes the
hook payload on stdin and needs nothing vendored into the repo:

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "npx agent-done-or-not stop-gate"
      }]
    }]
  }
}
```

`agent-done-or-not init --claude-hook` also copies the gate scripts into the
repo automatically, so a generated hook that points at local files resolves.

## Installation options

| Method | Command |
|---|---|
| Agent Skill (this) | `npx skills add mohamedzhioua/agent-done-or-not` |
| npm/npx | `npx agent-done-or-not capture --label check -- <cmd>` |
| One-liner installer | `curl -fsSL https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/install.sh \| sh` |
| Claude Code Plugin | `claude plugin install agent-done-or-not` |
| Homebrew | `brew install mohamedzhioua/tap/agent-done-or-not` |
| Scoop (Windows) | `scoop install agent-done-or-not` |
| Pre-commit hook | `id: agent-done-assert` in `.pre-commit-config.yaml` |
| GitHub Action | `uses: mohamedzhioua/agent-done-or-not@v0` |

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `AGENT_DONE_TTL` | `3600` | Receipt freshness window in seconds |
| `AGENT_DONE_MAX_RETRIES` | `10` | Anti-infinite-loop safety valve |
| `AGENT_DONE_DIR` | `<repo>/.agent-proof` | Where receipts are stored |
| `AGENT_DONE_SESSION` | (from hook payload) | Session isolation |
| `AGENT_DONE_OFF` | — | Set to `1` to disable (escape hatch) |
| `AGENT_DONE_BIND_STATE` | — | Set to `1` to make a git commit/tree/dirty mismatch against the newest passing receipt a hard failure/block instead of an advisory warning |
