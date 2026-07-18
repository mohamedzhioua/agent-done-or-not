# Claim markers — the `audit` contract

`done-gate.sh audit` (and `done-gate.ps1 audit`) diffs what an agent **claimed**
against the content-hashed **receipts** of what it actually ran. It reads claims
from two sources:

1. **Structured claim markers** the agent emits — the contract. Precise and
   unambiguous.
2. **Transcript heuristics** — a conservative fallback for claim-shaped prose
   with no marker. Heuristic claims are tagged `inferred` and are never silently
   upgraded to `backed`.

Markers are the reliable path. Instruct your agent to emit one for every outcome
it asserts.

## Marker syntax

```
<agent-done:claim label="LABEL" exit="N" sha256="HEX" />
```

- `label` (**required**) — the check's label, matching the `--label` you passed
  to `done-gate.sh capture`. A marker with no `label` is reported `UNPARSED`,
  never trusted.
- `exit` (optional) — the exit code being claimed. **Omitting `exit` asserts the
  check passed** (exit 0). Add `exit="N"` to claim a specific code.
- `sha256` (optional) — the sha256 of the captured output the agent is quoting.
  When present, `audit` checks it against the recorded receipt hash.

Emit one self-closing marker per claim, anywhere in your summary:

```
Done. Tests and lint pass.
<agent-done:claim label="test" exit="0" sha256="9f2c…" />
<agent-done:claim label="lint" exit="0" />
```

## Paste-ready agent instruction

Add this to your agent's system prompt, `CLAUDE.md`, `AGENTS.md`, or skill:

```text
When you claim you ran a check ("tests pass", "lint clean", "build succeeds"),
you MUST have first recorded it with:

    done-gate.sh capture --label <name> -- <the exact command>

and then emit a claim marker in your final summary, one per check:

    <agent-done:claim label="<name>" exit="<the real exit code>" />

Use the SAME <name> you passed to capture. Omitting exit asserts the check
passed. Do not emit a marker for a check you did not actually run — an
unbacked marker is caught by `done-gate.sh audit` and fails the gate.
```

## Verdicts

`audit` joins each claim to the receipt ledger by `label` and returns:

| Verdict | Meaning |
|---|---|
| `BACKED` | A matching execution receipt exists; exit and hash are consistent. |
| `UNBACKED` | The claim was asserted but **no receipt exists** — it was never run. |
| `MISREPORTED` | Claimed success (exit 0) but the recorded exit code is non-zero. |
| `INTEGRITY_MISMATCH` | The claimed `sha256` does **not** match the recorded hash. |
| `UNPARSED` | Claim-shaped text with no bindable label — reported, never counted as backed. |

> **Not "TAMPERED".** A hash mismatch proves the quoted output differs from the
> recorded output — not *who* changed it or *why*. `audit` reports the mismatch;
> it does not assign blame.

Only **execution** receipts (`disposition=reexecuted`, or legacy v0/v1) can back a
claim — an asserted claim/verdict record can never satisfy `audit` (see
[`claim.schema.json`](../claim.schema.json)).

`audit` exits **non-zero** if any claim is `UNBACKED`, `MISREPORTED`, or
`INTEGRITY_MISMATCH`. `UNPARSED` claims are surfaced but do not by themselves
change the exit code — coverage is always reported, never hidden.

## Usage

```bash
# audit a written summary against the latest run's ledger
done-gate.sh audit --transcript summary.md

# a specific run, machine-readable
done-gate.sh audit --transcript summary.md --run 20260718T0000Z --json

# from a pipe (e.g. a hook)
printf '%s' "$agent_summary" | done-gate.sh audit --transcript -
```

## SubagentStop hook (Claude Code)

`subagent-audit.sh` audits a **subagent's** summary before the parent session
trusts it — the direct answer to a parent blindly believing a subagent's "I ran
X and it passed." It **blocks** (exit 2) only on a real finding (`UNBACKED` /
`MISREPORTED` / `INTEGRITY_MISMATCH`) and **fails open** on an ambiguous payload
or when there is no ledger to audit against, so it never wedges a session.

Add to your Claude Code `settings.json` (or plugin `hooks.json`) — opt-in:

```json
{
  "hooks": {
    "SubagentStop": [
      { "hooks": [
        { "type": "command",
          "command": "bash \"$CLAUDE_PROJECT_DIR/subagent-audit.sh\"" }
      ] }
    ]
  }
}
```

Escape hatch: `export AGENT_DONE_OFF=1`. Loop-guarded via `stop_hook_active`.

## What it does not do

- It does not judge whether the check was the **right** check (that's an eval
  concern), only whether the claim about running it is true.
- Heuristic (`inferred`) claims are best-effort substring binding — precise
  diffs require markers. The hook still blocks only on unbacked/misreported/
  integrity findings, and coverage (marker vs inferred, unparsed count) is always
  reported.
