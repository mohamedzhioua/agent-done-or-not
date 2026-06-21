# Install — 60 seconds

You need two files at your repo root: `done-gate.sh` (the engine) and, for hard
enforcement, `stop-gate.sh` (the hook). Add `.agent-proof/` to your
`.gitignore`.

```bash
curl -O https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/done-gate.sh
curl -O https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/stop-gate.sh
chmod +x done-gate.sh stop-gate.sh
echo '.agent-proof/' >> .gitignore
```

---

## Claude Code — hard enforcement (recommended)

Add the Stop hook to `.claude/settings.json` (project) or `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/stop-gate.sh\"" } ] }
    ]
  }
}
```

Then drop the rule into your `CLAUDE.md` (copy the block from this repo's
`CLAUDE.md`). Now Claude cannot end a turn claiming "done" until a fresh passing
receipt exists.

## Cursor

Cursor has no hard stop hook, so the rule is the enforcement surface. Copy this
repo's `.cursorrules` into your project. The agent will run checks through
`done-gate.sh`, and every receipt is still recorded in `.agent-proof/` for you
(and CI) to inspect.

## Codex / other harnesses

Copy this repo's `AGENTS.md`. If your harness supports a stop/finish hook, wire
`stop-gate.sh` into it the same way as Claude Code for hard enforcement.

---

## Use it

```bash
# Capture a verifying check — exits with the command's own code:
bash done-gate.sh capture --label test -- npm test

# See the receipts:
bash done-gate.sh show

# Turn the gate off temporarily:
export AGENT_DONE_OFF=1
```

## Knobs

| Env var | Default | Meaning |
|---|---|---|
| `AGENT_DONE_OFF` | unset | Set to `1` to disable the stop-gate (escape hatch). |
| `AGENT_DONE_TTL` | `3600` | Seconds before a receipt is considered stale and rejected. `0` disables the freshness check. |
| `AGENT_DONE_MAX_RETRIES` | `10` | Consecutive blocks per session before the gate fails open (loudly) to avoid an infinite stop loop. |
| `AGENT_DONE_DIR` | `<repo>/.agent-proof` | Where receipts are stored. |
| `AGENT_DONE_SESSION` | unset | If your harness exports a session id, receipts segregate per session. |
