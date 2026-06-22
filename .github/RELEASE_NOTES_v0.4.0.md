# v0.4.0 — native packaging for the agent-skill ecosystems

v0.4.0 makes `agent-done-or-not` installable as a first-class citizen of the two
agent-skill ecosystems — a **Claude Code plugin** and a **skills.sh Agent
Skill**. Both are thin wrappers; the canonical bash core stays the source of
truth (no duplicated logic).

## What's new
- **Claude Code plugin** — hard "prove done" enforcement in one install:
  ```bash
  claude plugin marketplace add mohamedzhioua/agent-done-or-not
  claude plugin install agent-done-or-not
  ```
  Ships `.claude-plugin/plugin.json`, a Stop hook (`hooks/hooks.json` →
  `bash "${CLAUDE_PLUGIN_ROOT}/stop-gate.sh"`), and a single-plugin
  self-marketplace (`.claude-plugin/marketplace.json`). Validated with
  `claude plugin validate`.
- **Agent Skill (skills.sh)** — install the proof-of-done rule for any agent:
  ```bash
  npx skills add mohamedzhioua/agent-done-or-not
  ```
  `skills/done-or-not/SKILL.md` packages the rule; the README carries the live
  skills.sh install-count badge. The nested skill also rides along as bundled
  context for the Claude plugin.

## Notes
- 44-test suite, green on Ubuntu + macOS (plus the action self-test).
- Completes the P1 distribution arc: installer + Action + pre-commit (v0.3.0)
  and plugin + skill (v0.4.0).

**Full changelog:** see [CHANGELOG.md](https://github.com/mohamedzhioua/agent-done-or-not/blob/main/CHANGELOG.md).
