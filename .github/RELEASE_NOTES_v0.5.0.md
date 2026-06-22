# v0.5.0 — run the gate straight from npx

v0.5.0 adds an **npm package wrapper** so you can run the proof-of-done gate
without cloning the repo — handy in a CI step or an npm script.

## What's new
- **npm / npx** — `agent-done-or-not` on npm:
  ```bash
  npx agent-done-or-not capture --label test -- npm test
  npx agent-done-or-not assert --label test --ttl 3600
  ```
  A **zero-dependency** Node shim (`bin/agent-done-or-not.js`) forwards every
  argument to the bundled `done-gate.sh`, preserves the caller's working
  directory (so `.agent-proof/` lands in your repo), and exits with the
  underlying command's own code. Requires `bash` on PATH — Git Bash on Windows.
  The published tarball bundles only the engine, the scripts, the schema, and
  the drop-in rules (10 files).

## Notes
- 49-test suite, green on Ubuntu + macOS (plus the action self-test); the npm
  shim is covered end-to-end (capture writes a receipt in cwd; assert
  propagates pass/fail exit codes).
- Thin wrapper — the canonical bash core is unchanged.

**Full changelog:** see [CHANGELOG.md](https://github.com/mohamedzhioua/agent-done-or-not/blob/main/CHANGELOG.md).
