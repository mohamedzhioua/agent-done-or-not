---
name: done-or-not
description: Proof-of-done gate — before claiming a task is complete, run the verifying check through done-gate.sh and only report done after a fresh PASSING receipt. Use whenever an agent is about to say a task/build/test is finished.
license: MIT
metadata:
  author: mohamedzhioua
  version: "0.4.0"
---

# done-or-not

## When to use

Use this skill whenever you are about to tell the user that a task, build, test,
fix, or verification step is finished. A completion claim requires proof from the
gate, not confidence or memory.

## How to use

1. Identify the command that proves the work. Choose the smallest check that
   actually verifies the claim: tests, build, typecheck, lint, a `curl` against a
   running endpoint, or another command with meaningful pass/fail behavior.
2. Run the verifying command through the proof gate:

   ```bash
   bash done-gate.sh capture --label check -- <your verifying command>
   ```

   The gate records the command, its exit code, and a SHA-256 of the output. It
   exits with the command's own code, so a failing check fails the capture.
3. Only report the work complete after a fresh PASSING receipt exists.
4. If the check fails, fix the problem and capture again. Never report success
   on a red check.

The Stop gate enforces this rule where the harness supports it: it blocks the
agent from ending the turn until a fresh passing receipt exists. Do not work
around the gate; produce the proof.
