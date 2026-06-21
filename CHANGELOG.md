# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-06-21

First release. A single-file, zero-dependency proof-gate that blocks an AI
coding agent from claiming "done" until a fresh, passing, unconsumed
verification receipt exists. Works with Claude Code (hard Stop-hook
enforcement), Cursor, and Codex (rule-based).

### Added
- `done-gate.sh` — `capture` / `verify` / `show`. Runs a check, streams its
  output, records a tamper-evident JSONL receipt (command, exit code, SHA-256 of
  output, timestamp, epoch, session), and exits with the command's own code.
- `stop-gate.sh` — Stop-event hook. Allows a stop only for a passing, fresh,
  unconsumed receipt; fails closed on any malformed/missing/stale proof state;
  bounded anti-infinite-loop safety valve via `AGENT_DONE_MAX_RETRIES`.
- Drop-in behavior rules: `CLAUDE.md`, `.cursorrules`, `AGENTS.md`.
- `proof.schema.json` — documented receipt shape.
- `tests/run.sh` — 18 behavior tests; CI on Ubuntu + macOS.
- Docs: README, `examples/install.md`, `CONTRIBUTING.md`.

### Security
- Hardened after an independent cross-model (Codex) review: removed a
  loop-guard bypass, switched all malformed-state handling to fail-closed, made
  consume-on-allow persistence mandatory, moved freshness to the receipt-recorded
  epoch (not forgeable file mtime), and validated `--run`/`--label` against path
  traversal.

[0.1.0]: https://github.com/mohamedzhioua/agent-done-or-not/releases/tag/v0.1.0
