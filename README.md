# agent-done-or-not

[![CI](https://github.com/mohamedzhioua/agent-done-or-not/actions/workflows/test.yml/badge.svg)](https://github.com/mohamedzhioua/agent-done-or-not/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/tag/mohamedzhioua/agent-done-or-not?label=release)](https://github.com/mohamedzhioua/agent-done-or-not/releases)
![Dependencies: none](https://img.shields.io/badge/dependencies-none-brightgreen.svg)

**Your AI agent just said "Done ✅" — but did it verify?** This one-file gate
forces it to *prove* the claim with a hash before it can declare success. Works
with **Claude Code, Cursor, and Codex**. Copy. Paste. Ship.

```text
agent: All tests pass — task complete! ✅
stop-gate: BLOCKED — no NEW passing check since your last completion — re-verify this change
agent: $ bash done-gate.sh capture --label test -- npm test
       ✗ 1 test failed (exit=1)
stop-gate: BLOCKED — your most recent check FAILED (exit=1) — fix it, don't ship it
```

That's the whole point: **"it works" stops being a confidence claim and becomes
a receipt.**

▶ Watch the terminal cast: [`docs/demo.cast`](docs/demo.cast) — play locally with
`asciinema play docs/demo.cast`.

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

### Why not just put "always run the tests" in CLAUDE.md?

| | a rule in `CLAUDE.md` | **agent-done-or-not** |
|---|---|---|
| Agent *can* ignore it | yes — it's a suggestion | **no** — the Stop hook blocks the turn |
| Proof it actually ran | none | hashed receipt (`proof.json`) |
| Failing check caught | only if the agent admits it | always — exit code is recorded |
| Works in CI / pre-commit | no | yes — `done-gate.sh assert` |
| Cross-tool | per-tool prose | one engine for Claude, Cursor, Codex |
| Dependencies | — | none (`bash` + `git` + sha) |

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
{"label":"test","command":"npm test","exit_code":0,"sha256":"9f2c…","log":".agent-proof/…/test.log","at":"2026-06-21T19:44:00Z","epoch":1781034240,"session":""}
```

See [`examples/proof.jsonl`](examples/proof.jsonl) for a full ledger sample.

### Gate your CI / pre-commit too

`assert` checks the ledger without running anything — perfect for a CI step or a
pre-commit hook that refuses to proceed unless the right checks passed:

```bash
# Require BOTH a passing test and build receipt, no older than 1h,
# and make sure the "test" receipt really came from your test runner:
bash done-gate.sh assert --label test --label build \
  --allow-command-regex '(npm|pnpm) test' --ttl 3600

# Machine-readable for Actions / tooling:
bash done-gate.sh assert --json --label test
# {"ok":true,"run":"…","ttl":3600,"checks":[{"label":"test","ok":true,…}]}
```

Every command supports `--json` for stable, dependency-free output.

## How it works

1. **`done-gate.sh capture`** runs your check, streams its output, and appends a
   receipt to `.agent-proof/<run>/ledger.jsonl`. It exits with the command's own
   exit code.
2. **`stop-gate.sh`** is a Stop-event hook. It blocks the agent from ending its
   turn unless the most recent receipt is:
   - **passing** (a red check can never mean "done"),
   - **fresh** — judged by the epoch recorded *inside* the receipt (not file
     mtime, which `touch` could forge); older than `AGENT_DONE_TTL` (default 1h)
     is rejected, so it never honors yesterday's ledger, and
   - **not already used** to clear a previous stop (every completion needs its
     own proof).

**It fails closed.** Once a stop is being gated, any missing, empty, unparseable,
or stale proof state *blocks*. The only ways past are a verified passing receipt,
the escape hatch, or an anti-infinite-loop safety valve (it gives up and warns
loudly after `AGENT_DONE_MAX_RETRIES` consecutive blocks so the agent can never
get permanently stuck).

Dependency-free: portable `bash` + `git` + one of `sha256sum`/`shasum`/`python`.
No network, no LLM, no config file. The receipt format is documented in
[`proof.schema.json`](proof.schema.json). Hardened with an independent
cross-model (Codex) security review — see [CONTRIBUTING.md](CONTRIBUTING.md).

## How it can — and can't — be fooled (threat model)

`agent-done-or-not` is built to resist an agent that *wants* to look done. It is
a forcing function, not a sandbox; here's the honest boundary.

**It stops these:**
- Claiming "done" with no check run → blocked (no receipt).
- A failing check dressed up as success → blocked (`capture` records and exits
  with the real non-zero code).
- Re-using an old green run → blocked (receipts are consumed; freshness uses the
  epoch *inside* the receipt, so `touch` won't refresh it).
- Malformed/empty proof state to slip through → blocked (the gate **fails
  closed**).
- An infinite block loop → bounded safety valve (`AGENT_DONE_MAX_RETRIES`).
- Running the wrong class of check → constrain it with
  `assert --allow-command-regex`.

**It does NOT claim to stop these** (out of scope by design):
- Choosing a *weak* check (an empty test suite "passes"). You pick the command;
  pair it with `--allow-command-regex` and real tests.
- An agent that rewrites the ledger files by hand. If your agent can freely edit
  `.agent-proof/` it can forge anything — treat the ledger as you would any
  workspace file. (`verify --sha` lets a second party confirm a specific hash.)
- Hard enforcement on harnesses without a stop hook (Cursor): there the rule is
  advisory, but every receipt is still recorded for you and CI to audit.

Report a bypass — see [SECURITY.md](SECURITY.md). It's the most valuable issue
you can file.

## Escape hatch

```bash
export AGENT_DONE_OFF=1   # disable the gate
```

## FAQ

**Does it need Node / Python / jq?** No. Just `bash`, `git`, and one of
`sha256sum` / `shasum` / `python` for hashing.

**Windows?** Works under Git Bash / MSYS today (CI covers Linux + macOS; a
native PowerShell port is on the roadmap).

**Won't it get my agent stuck?** No — after `AGENT_DONE_MAX_RETRIES` consecutive
blocks it fails open with a loud warning, and `AGENT_DONE_OFF=1` disables it.

**Is the receipt private?** Yes — `.agent-proof/` is local and gitignored; it's
never committed.

**What's the difference between `capture` and `assert`?** `capture` *runs* a
check and records proof (use it in the agent loop). `assert` *checks the ledger*
without running anything (use it in CI / pre-commit).

## Credits

Extracted and sharpened from the evidence/verify-gate layer of
**[zhioua-os](https://github.com/zhioua-os)**, an AI engineering OS for coding
agents ("replace trust with evidence"). MIT licensed — fork it, ship it.
