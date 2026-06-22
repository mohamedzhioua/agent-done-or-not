# v0.2.0 — useful beyond the agent loop (CI / pre-commit) + machine-readable

v0.2.0 takes the proof-gate from an in-loop guardrail to something you can also
gate **CI, pre-commit, and release** on — and makes every decision
machine-readable so other tools can build on it.

## What's new
- **`done-gate.sh assert`** — verify the ledger **without running anything**, for
  CI / pre-commit / release gates. Require one or more labels (`--label`,
  repeatable), reject stale receipts (`--ttl`), and constrain the recorded
  command class (`--allow-command-regex` / `AGENT_DONE_ALLOWED_COMMANDS`).
  ```bash
  bash done-gate.sh assert --label test --label build --ttl 3600
  ```
- **`--json`** on `capture`, `assert`, `verify`, and `show` — stable,
  dependency-free decision objects for Actions, hooks, and editor integrations.
- **Trust pack:** README badges, a comparison table (vs a plain `CLAUDE.md`
  rule), a "how it can and can't be fooled" threat model, an FAQ, `SECURITY.md`,
  `examples/proof.jsonl`, and an asciinema cast at `docs/demo.cast`.

## Changed
- `epoch` is documented in `proof.schema.json`; freshness is judged from the
  recorded epoch, **never** file mtime.
- Tests: 18 → 28 (assert pass/fail/all-labels/ttl/regex + `--json` parse checks),
  green on Ubuntu + macOS.

## Notes
- Backward compatible with v0.1.0 — `capture` / `verify` / `show` are unchanged;
  `assert` and `--json` are additive.

**Full changelog:** see [CHANGELOG.md](https://github.com/mohamedzhioua/agent-done-or-not/blob/main/CHANGELOG.md).
