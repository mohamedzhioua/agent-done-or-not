# Install — 60 seconds

From the repo you want to protect:

```bash
npx agent-done-or-not init --yes
```

Prefer a shell-only install?

```bash
curl -fsSL https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/install.sh | sh
```

The installer writes only to the current directory: `done-gate.sh`,
`stop-gate.sh`, executable bits, and a `.agent-proof/` entry in `.gitignore`.

Inspect-first alternative:

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

### Claude Code plugin

```bash
claude plugin marketplace add mohamedzhioua/agent-done-or-not
claude plugin install agent-done-or-not
```

The plugin is a thin wrapper: the bash core stays canonical in this repo, and
the plugin wires `stop-gate.sh` as the `Stop` hook for hard enforcement. You
still drop the `CLAUDE.md` rule into the protected repo for the agent-facing
instruction.

### Agent Skill

```bash
npx skills add mohamedzhioua/agent-done-or-not
```

Installs the proof-of-done rule as a skill for Claude Code / Codex / other
agents. A skill-only install does not copy repo-root `done-gate.*` scripts, so
use the portable command from the skill:

```bash
npx agent-done-or-not capture --label check -- <your verifying command>
```

Run `agent-done-or-not init` or the shell installer when you want local
`done-gate.*` scripts and hook config in the protected repo.

### npm / npx

```bash
npx agent-done-or-not capture --label test -- npm test
npx agent-done-or-not assert --label test --ttl 3600
```

Runs the gate without cloning. The wrapper uses `done-gate.sh` when Bash is
available and falls back to `done-gate.ps1` through `pwsh` / `powershell` on
Windows.

## Cursor

Cursor has no hard stop hook, so the rule is the enforcement surface. Copy this
repo's `.cursorrules` into your project. The agent will run checks through
`done-gate.sh`, and every receipt is still recorded in `.agent-proof/` for you
(and CI) to inspect.

## Codex / other harnesses

Copy this repo's `AGENTS.md`. If your harness supports a stop/finish hook, wire
`stop-gate.sh` into it the same way as Claude Code for hard enforcement.

---

## CI

Use the GitHub composite action to gate a job on receipts created earlier in the
same checkout:

```yaml
- uses: actions/checkout@v4
- uses: mohamedzhioua/agent-done-or-not@v0
  with:
    mode: assert
    labels: "test build"
    ttl: "3600"
```

Run `actions/checkout` first, then produce receipts earlier in the job with
`bash done-gate.sh capture` before the action asserts them.

### Pre-commit hook

Add to `.pre-commit-config.yaml` in any repo that uses this tool:

```yaml
repos:
  - repo: https://github.com/mohamedzhioua/agent-done-or-not
    rev: v0.7.0
    hooks:
      - id: agent-done-assert
```

Commits are blocked unless a fresh passing receipt exists in `.agent-proof/`.
Pass extra options via `args:`, e.g. `args: [--label, test, --ttl, "3600"]`.

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
| `AGENT_DONE_ALLOWED_COMMANDS` | unset | Regex the recorded command must match for `assert` to accept a receipt (same as `--allow-command-regex`). |
| `AGENT_DONE_DIR` | `<repo>/.agent-proof` | Where receipts are stored. |
| `AGENT_DONE_SESSION` | unset | If your harness exports a session id, receipts segregate per session. |

## Gate CI / pre-commit with `assert`

`assert` reads the ledger without running anything — use it where you want to
refuse to proceed unless the right checks passed this run:

```bash
bash done-gate.sh assert --label test --label build --ttl 3600
bash done-gate.sh assert --json --label test   # machine-readable
```
