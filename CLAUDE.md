<!--
  agent-done-or-not — drop-in rule for Claude Code.
  Copy the block below into your project's CLAUDE.md (or keep this file as-is at
  repo root). Pair it with the Stop hook in examples/install.md so the rule is
  ENFORCED, not just suggested.
-->

# Proof-of-Done Rule

Before you tell the user a task is complete, you MUST verify it through the
proof gate. Saying "done" without a passing receipt is not allowed.

1. Identify the command that proves the work (tests, build, typecheck, lint, a
   `curl` against the running endpoint — whatever actually demonstrates it).
2. Run it through the gate:

   ```bash
   bash done-gate.sh capture --label check -- <your verifying command>
   ```

   This records the command, its exit code, and a SHA-256 of its output. It
   exits with the command's own code, so a failing check fails here.
3. Only after a PASSING receipt may you report the task complete.
4. If the check fails, fix the code and capture again — never report success on
   a red check.

The Stop gate will block you from ending the turn until a fresh passing receipt
exists. Do not work around it; produce the proof.
