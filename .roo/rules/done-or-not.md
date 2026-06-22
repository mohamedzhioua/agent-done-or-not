# Proof-of-Done Rule (agent-done-or-not)

Applies to Roo operating in this repo.

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

On Windows, replace `bash done-gate.sh` with `pwsh -File done-gate.ps1`.

See `examples/install.md` for wiring a hard stop-gate where your harness
supports stop/finish hooks.
