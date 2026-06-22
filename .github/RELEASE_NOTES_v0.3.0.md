# v0.3.0 — three drop-in ways to adopt the gate

Distribution release. The proof-gate core was already stable; v0.3.0 makes it
trivial to add to any repo without copy-pasting files. Builds on the `assert` +
`--json` contract from v0.2.0.

## What's new
- **`install.sh` one-liner** — bootstrap any repo in one command:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not/main/install.sh | sh
  ```
  Conservative, inspectable POSIX `sh`: drops `done-gate.sh` + `stop-gate.sh`
  into the current repo, marks them executable, and adds `.agent-proof/` to
  `.gitignore` (idempotent). Pin a ref with `REF=v0.3.0`; offline installs via
  `AGENT_DONE_LOCAL_SRC`. Prefer to inspect first? The manual two-file method is
  still documented.
- **GitHub Action** — gate a CI job on proof-of-done:
  ```yaml
  - uses: actions/checkout@v4
  - uses: mohamedzhioua/agent-done-or-not@v0.3.0
    with:
      mode: assert
      labels: "test build"
      ttl: "3600"
  ```
  A composite action that resolves its own `done-gate.sh` and asserts the
  consumer's receipt ledger. Self-test workflow dogfoods both the pass and the
  expected-failure path.
- **Pre-commit framework hook** — block commits that lack a fresh passing receipt:
  ```yaml
  repos:
    - repo: https://github.com/mohamedzhioua/agent-done-or-not
      rev: v0.3.0
      hooks:
        - id: agent-done-assert
  ```

## Notes
- 38-test suite, green on Ubuntu + macOS (plus the action self-test).
- Every new surface is a thin wrapper — the canonical bash core is unchanged.

**Full changelog:** see [CHANGELOG.md](https://github.com/mohamedzhioua/agent-done-or-not/blob/main/CHANGELOG.md).
