# Proof-of-Done Rule (agent-done-or-not)

Applies to any agent operating in this repo (Codex, and other harnesses that
read `AGENTS.md`).

Before reporting a task complete, you MUST verify it through the proof gate.
Claiming "done" without a passing receipt is not allowed.

1. Run the verifying command through the gate:

   ```bash
   bash done-gate.sh capture --label check -- <your verifying command>
   ```

   It records the command, its exit code, and a SHA-256 of the output, and exits
   with the command's own code — so a failing check fails here.
2. Only report completion after a PASSING receipt.
3. If the check fails, fix the code and capture again. Never report success on a
   red check.

## Claim markers (for `audit`)

When you assert a check passed, also emit a claim marker in your final summary so
`done-gate.sh audit` can diff the claim against the receipt ledger:

```
<agent-done:claim label="test" exit="0" />
```

Use the same `--label` you passed to `capture`; omitting `exit` asserts a pass.
An unbacked marker is caught by `audit`. Full contract and paste-ready
instruction: [`docs/markers.md`](docs/markers.md).

See `examples/install.md` for wiring a hard stop-gate where your harness
supports stop/finish hooks.
