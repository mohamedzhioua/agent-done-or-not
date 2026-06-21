# agent-done-or-not

**Your AI agent just said "Done ✅" — but did it verify?** This one-file gate
forces it to *prove* the claim with a hash before it can declare success. Works
with **Claude Code, Cursor, and Codex**. Copy. Paste. Ship.

<!-- Add the demo GIF here once recorded: agent says "Done!" → gate blocks → it
     actually runs the check → a test fails → it gets caught. -->
<!-- ![demo](docs/demo.gif) -->

```text
agent: All tests pass — task complete! ✅
stop-gate: BLOCKED — no NEW passing check since your last completion — re-verify this change
agent: $ bash done-gate.sh capture --label test -- npm test
       ✗ 1 test failed (exit=1)
stop-gate: BLOCKED — your most recent check FAILED (exit=1) — fix it, don't ship it
```

That's the whole point: **"it works" stops being a confidence claim and becomes
a receipt.**

---

## Why

AI coding agents routinely announce a task is "done" without running anything to
back it up. It's the loudest complaint in the agent ecosystem
([claude-code#42796](https://github.com/anthropics/claude-code/issues/42796)),
and the fix is simple: don't let the agent *say* done — make it *show* done.

`agent-done-or-not` records every check as a tamper-evident receipt (command +
exit code + SHA-256 of the output) and blocks the agent from finishing until the
most recent check is a fresh, **passing** one. Because the capture step exits
with the command's own code, **a failing check can't be dressed up as success.**

## Install (60 seconds)

```bash
curl -O https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/done-gate.sh
curl -O https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/stop-gate.sh
chmod +x done-gate.sh stop-gate.sh
echo '.agent-proof/' >> .gitignore
```

Then wire the rule + hook for your tool — see **[examples/install.md](examples/install.md)**.

- **Claude Code** → drop in `CLAUDE.md` + the `Stop` hook = hard enforcement.
- **Cursor** → drop in `.cursorrules`.
- **Codex / others** → drop in `AGENTS.md`.

## Use

```bash
# Run any check through the gate — it exits with the command's own code:
bash done-gate.sh capture --label test -- npm test

# Inspect the receipts:
bash done-gate.sh show
```

```json
{"label":"test","command":"npm test","exit_code":0,"sha256":"9f2c…","log":".agent-proof/…/test.log","at":"2026-06-21T19:44:00Z","session":""}
```

## How it works

1. **`done-gate.sh capture`** runs your check, streams its output, and appends a
   receipt to `.agent-proof/<run>/ledger.jsonl`. It exits with the command's own
   exit code.
2. **`stop-gate.sh`** is a Stop-event hook. It blocks the agent from ending its
   turn unless the most recent receipt is:
   - **passing** (a red check can never mean "done"),
   - **fresh** (older than `AGENT_DONE_TTL`, default 1h, is rejected — no
     honoring yesterday's ledger), and
   - **not already used** to clear a previous stop (every completion needs its
     own proof).

Dependency-free: portable `bash` + `git` + one of `sha256sum`/`shasum`/`python`.
No network, no LLM, no config file. The receipt format is documented in
[`proof.schema.json`](proof.schema.json).

## Honest limits

This is a **forcing function, not a semantic oracle.** It guarantees a check ran
and passed since your last completion — it does not judge whether it was the
*right* check. You choose the command; the gate makes the agent actually run it.
Binding a proof to the specific task claim is on the v0.2 roadmap.

On Cursor and other harnesses without a hard stop hook, the rule is advisory but
the receipts are still recorded — so you (and CI) can always audit what the agent
actually verified.

## Escape hatch

```bash
export AGENT_DONE_OFF=1   # disable the gate
```

## Credits

Extracted and sharpened from the evidence/verify-gate layer of an AI engineering
OS ("replace trust with evidence"). MIT licensed — fork it, ship it.
