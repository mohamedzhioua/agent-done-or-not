# v0.1.0 — make your AI agent prove "done"

**Your AI agent just said "Done ✅" — but did it verify?** `agent-done-or-not` is
a single-file, zero-dependency proof-gate that forces it to back the claim with a
hash before it can finish. Works with **Claude Code, Cursor, and Codex**.

## What's in it
- **`done-gate.sh`** — runs your real check, streams output, records a
  tamper-evident receipt (command + exit code + SHA-256), and **exits with the
  command's own code** so a failing check can't be dressed up as green.
- **`stop-gate.sh`** — a Stop-event hook that blocks "done" unless the most
  recent receipt is **passing, fresh, and not already used**. It **fails closed**
  and can't be looped forever (bounded safety valve).
- Drop-in rules for all three tools (`CLAUDE.md`, `.cursorrules`, `AGENTS.md`),
  a documented receipt schema, and an 18-test suite (green on Ubuntu + macOS).

## Install (60 seconds)
```bash
curl -O https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/done-gate.sh
curl -O https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/stop-gate.sh
chmod +x done-gate.sh stop-gate.sh
echo '.agent-proof/' >> .gitignore
```
Then wire it for your tool — see [examples/install.md](https://github.com/mohamedzhioua/agent-done-or-not/blob/main/examples/install.md).

## Notes
- Hardened with an independent cross-model (Codex) security review before release.
- It's a **forcing function, not a semantic oracle** — it makes the agent run a
  check and proves it passed; you choose the check. Task-specific proof binding
  is on the v0.2 roadmap.

**Full changelog:** see [CHANGELOG.md](https://github.com/mohamedzhioua/agent-done-or-not/blob/main/CHANGELOG.md).
