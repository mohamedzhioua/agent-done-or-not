# v0.9.0 — state-bound trust

v0.8.0 defined *what counts as done*. **v0.9.0 binds every receipt to the source
it verified** and closes the Windows and setup gaps that blocked adoption. A
green receipt from before your last edit no longer looks identical to a fresh
one, and the hard Stop gate is now as strict as `assert`.

## Highlights

- **Git-state binding.** `capture` now records the `commit` (full HEAD SHA),
  `tree`, and `dirty` working-tree state in every receipt. Empty/`false` outside
  a git repo, so nothing breaks off-VCS.
- **State-drift detection.** `assert`, the Stop gate, and `report` warn when the
  newest passing receipt was captured against a **different commit** (or a dirty
  tree) — the stale-CI-cache / edit-after-check gap. Advisory by default; set
  `AGENT_DONE_BIND_STATE=1` to make drift a hard failure/block.
- **Policy-aware Stop gate.** `stop-gate.sh` / `stop-gate.ps1` now enforce an
  `agent-done.json` policy — a single passing receipt of any label no longer
  clears the gate when a policy requires more (parity with `assert`). Fails
  closed if it can't evaluate the policy.
- **Test-file-diff guard.** `report` flags a "done" claim sitting on uncommitted
  changes to test/spec files (advisory) — the most-cited agent check-gaming
  pattern.
- **`npx agent-done-or-not stop-gate`.** Run the Stop hook with no vendored
  scripts; it pipes the hook payload on stdin.

## Fixes (adoption blockers)

- **`init --claude-hook` now installs a working hook** — it copies the gate
  scripts into the repo, so the generated hook resolves instead of pointing at
  missing files.
- **Windows PowerShell 5.1 encoding** — removed non-ASCII characters from
  `done-gate.ps1` that broke WinPS 5.1's UTF-8-no-BOM parse. All engine `.ps1`
  files are pure ASCII now.
- **npm wrapper Windows/WSL trap** — the wrapper tries PowerShell first on
  Windows, so a WSL `bash.exe` that chokes on a Windows path no longer aborts
  before the native `.ps1` engine.
- **Windows CI matrix** — CI runs the PowerShell parity suite under both Windows
  PowerShell 5.1 and PowerShell 7+, plus an npm-wrapper smoke, so these stay
  fixed.

## Positioning

The receipt is a **verification receipt** — evidence that the configured check
ran and passed against a specific commit. The SHA-256 is proof of the command's
output; it is *not* proof of semantic correctness. You still choose a command
that verifies what you claim.

Full details in [CHANGELOG.md](../CHANGELOG.md).
