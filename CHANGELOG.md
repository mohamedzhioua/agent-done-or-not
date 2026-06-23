# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.8.0] — 2026-06-23

The trust-layer release. v0.7.0 made the evidence *visible*; v0.8.0 lets a
maintainer define **what counts as done** and makes a completion claim
**shareable** — turning "a check passed" into "the *required* checks passed."

### Added
- **Required-checks policy** — an optional `agent-done.json` at the repo root
  declares the labels a green gate requires, each with an optional
  `command_regex`, plus a `ttl`:
  ```json
  { "required": [ { "label": "test", "command_regex": "(npm|pnpm) test" },
                  { "label": "build" } ], "ttl": 3600 }
  ```
  `done-gate.sh assert` (and the PowerShell port) read it automatically when no
  explicit `--label` is given. A label is satisfied only by a fresh, passing
  receipt whose recorded command matches its regex — so `true`/`echo ok` can no
  longer satisfy a `test` requirement. Resolution order is explicit `--label`
  (legacy) → policy file → most-recent receipt. New flags: `--policy <file>`
  and `--no-policy`. Policy mode searches **all** run dirs per label, so checks
  captured in separate runs still count. `assert --json` gains a `policy` key.
  Described by the new [`policy.schema.json`](policy.schema.json).
- **Wrong-check detection** — a label taxonomy (strong: test/build/typecheck/
  e2e/smoke/…; weak: lint/format/style/manual/docs). When the only passing
  evidence is a weak check, `assert` and `report` emit an advisory
  `latest proof is lint-only — this may not verify the requested behavior`
  warning. Advisory only: it never changes an exit code.
- **`report --format pr`** — a sticky, paste-ready GitHub-comment summary
  (✅/❌ status, commit, per-check bullets with command + age + sha) wrapped in
  `<!-- agent-done-or-not:proof -->` markers so it can be updated in place.
- **Human report card** — `report` (markdown) now leads with a `Proof of Done`
  card (status glyph, latest command, exit, relative age, output hash, commit)
  above the existing table.
- **Action PR comment** — the GitHub Action gains `pr-comment` and
  `github-token` inputs; on a pull request it upserts the sticky proof comment
  via `gh api`, without changing the job's pass/fail (assert still decides).
- **`init` polish** — `--claude` is now an alias for `--claude-hook`, and
  `--policy` scaffolds an `agent-done.json` from detected checks (never
  overwriting an existing one).

### Changed
- `assert --json` output now includes a top-level `policy` field (empty string
  in legacy/`--label` modes). All existing keys are unchanged.

## [0.7.0] — 2026-06-23

Adds a 60-second onboarding flow and an inspectable proof report, plus a
GitHub Action job summary — closing the gap between "the gate runs" and
"I can see the evidence."

### Added
- `agent-done-or-not init` — bootstraps proof-of-done in a repo. Detects the
  stack (npm/pnpm/yarn, Python, Go, Cargo, Maven/Gradle) and infers
  conservative `test`/`build`/`lint` labels only when the corresponding scripts
  or tools are present, falling back to a manual `check` label otherwise. Writes
  a managed, marker-delimited proof block into existing agent instruction files
  (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.windsurfrules`, `.clinerules`),
  preserving unrelated content and backing up any file it changes. `--dry-run`
  previews without writing; `--label`/`--command` override detection;
  `--claude-hook` also writes a Claude Code Stop hook into `.claude/settings.json`.
- `agent-done-or-not report --format markdown|html|json` — renders a compact
  proof summary from `.agent-proof` ledgers, with an explicit non-green state
  vocabulary (`missing`, `failed`, `stale`, `bypassed`, `local-only`), commit
  SHA, and dirty-tree status. Bypassed/stale/missing/failed states are never
  presented as verified.
- GitHub Action now writes a proof job summary to `$GITHUB_STEP_SUMMARY`
  (mode, labels, status, and HTML-escaped gate output) without changing the
  assert exit status.
- `npm run smoke` — a fast wrapper sanity check.

### Changed
- npm/skill docs now lead with `npx agent-done-or-not init` / `capture`, clarify
  the PowerShell fallback on Windows, and explain that a skill-only install
  provides instructions rather than repo-root gate scripts.
- Messaging tightened from "cryptographically proves correctness" to "records
  fresh evidence that configured checks ran."

### Fixed
- `report` now escapes agent-controlled receipt fields before rendering
  (markdown table cells and HTML), and `--format html` emits a real HTML table
  instead of an escaped raw-markdown dump.
- `init` preserves separation between the managed block and following content on
  re-runs, and never overwrites an existing backup file.
- GitHub Action job summary writes gate output into an HTML-escaped `<pre>`
  block so receipt/command text cannot inject markdown into the summary.
- `done-gate.ps1` writes captured output straight to the console
  (`[Console]::Out.WriteLine`) so it cannot leak into the function's return
  value.

## [0.6.0] — 2026-06-22

Completes Windows-native support and broadens agent coverage to every major
AI coding tool on the skills.sh platform.

### Added
- Native PowerShell port of the engine: `done-gate.ps1` (capture / assert /
  verify / show, `--json`, all flags and env vars) with behavior and a receipt
  format identical to `done-gate.sh` — runs on Windows PowerShell 5.1 and
  PowerShell 7+ with built-ins only, so Windows no longer needs Git Bash.
  Receipts from the two engines are interchangeable. Parity tests in
  `tests/run.ps1` (19 scenarios, pass under both PS hosts) are also exercised by
  `tests/run.sh` when a PowerShell host is on PATH (so CI covers them).
- `stop-gate.ps1` — native PowerShell Stop-event hook, a full parity port of
  `stop-gate.sh`. All 13 trust rules preserved: escape hatch, fail-closed on
  malformed/missing/stale state, freshness via receipt-recorded epoch, atomic
  consume-on-allow, and the retry counter with fail-open safety valve.
  Wires into Claude Code `settings.json` with one `powershell -NoProfile -File`
  command. 3 new parity test scenarios added to `tests/run.ps1`.
- Homebrew formula (`packaging/homebrew/agent-done-or-not.rb`) and Scoop manifest
  (`packaging/scoop/agent-done-or-not.json`), both pinned to the v0.6.0 source
  tarball + SHA-256. Each is a thin wrapper that installs the canonical
  `done-gate.sh`/`stop-gate.sh` engine and puts an `agent-done-or-not` launcher
  on PATH; `packaging/README.md` documents the tap/bucket publish steps.
- Agent rules files for the full skills.sh agent roster:
  - `.windsurfrules` — Windsurf
  - `.clinerules` — Cline
  - `.roo/rules/done-or-not.md` — Roo
  - `.zed/prompts/done-or-not.md` — Zed
  - `.goosehints` — Goose
  All five carry the same proof-of-done rule prose as `.cursorrules` and
  `AGENTS.md`, adapted to each agent's native file format and path convention.
- CI templates for GitLab CI (`docs/ci-templates/gitlab-ci.yml`) and Azure
  DevOps (`docs/ci-templates/azure-devops.yml`), joining the existing GitHub
  Actions composite action.
- Improved `skills/done-or-not/SKILL.md`: richer description, 20+ keywords for
  skills.sh discovery, PowerShell usage examples, full installation table, and
  configuration reference.

## [0.5.0] — 2026-06-22

### Added
- npm package wrapper (`agent-done-or-not`) — run the gate via
  `npx agent-done-or-not <capture|assert|verify|show> …` without cloning. A
  zero-dependency Node shim forwards to the bundled `done-gate.sh`, preserves
  the caller's cwd, and propagates the exit code. Requires `bash` on PATH.

## [0.4.0] — 2026-06-22

Native packaging for the two agent-skill ecosystems — a Claude Code plugin and
a skills.sh-installable Agent Skill — both thin wrappers over the canonical
bash core.

### Added
- Agent Skill package at `skills/done-or-not/SKILL.md` for installing the
  proof-of-done rule with `npx skills add mohamedzhioua/agent-done-or-not`, plus
  the live skills.sh install-count badge.
- Claude Code plugin wrapper manifest, Stop hook wiring, and marketplace catalog
  for installing hard proof-of-done enforcement without duplicating the bash
  core scripts.

## [0.3.0] — 2026-06-22

Distribution: three drop-in ways to adopt the gate in any repo — a one-liner
installer, a GitHub Action, and a pre-commit framework hook.

### Added
- `.pre-commit-hooks.yaml` and `hooks/pre-commit-assert.sh` -- consume this repo
  as a pre-commit framework hook (`id: agent-done-assert`) to block commits
  unless a fresh passing proof-of-done receipt exists in `.agent-proof/`.
- GitHub composite Action for asserting proof-of-done receipts from CI jobs.
- `install.sh` one-liner installer for copying `done-gate.sh` and
  `stop-gate.sh` into the current repo, marking them executable, and adding
  `.agent-proof/` to `.gitignore` idempotently.
- Offline installer test coverage via `AGENT_DONE_LOCAL_SRC`.

## [0.2.0] — 2026-06-21

Makes the tool genuinely useful beyond the agent loop (CI / pre-commit) and far
more credible for evaluators.

### Added
- **`done-gate.sh assert`** — verify the ledger without running anything, for CI,
  pre-commit, and release gates. Require one or more labels
  (`--label`, repeatable), reject stale receipts (`--ttl`), and constrain the
  recorded command class (`--allow-command-regex` / `AGENT_DONE_ALLOWED_COMMANDS`).
- **`--json`** on `capture`, `assert`, `verify`, and `show` — stable,
  dependency-free decision objects for Actions / hooks / editor integrations.
- **Trust pack:** README badges, a comparison table (vs a rule in `CLAUDE.md`),
  a "how it can and can't be fooled" threat model, an FAQ, `SECURITY.md`,
  `examples/proof.jsonl`, and an asciinema cast at `docs/demo.cast`.

### Changed
- `epoch` is now documented in `proof.schema.json`; freshness is judged from it,
  never file mtime.
- Tests: 18 → 28 (assert pass/fail/all-labels/ttl/regex + `--json` parse checks).

[0.2.0]: https://github.com/mohamedzhioua/agent-done-or-not/releases/tag/v0.2.0

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
