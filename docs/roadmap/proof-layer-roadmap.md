# Proof Layer Roadmap

Date: 2026-06-23
Repo: agent-done-or-not
Purpose: handoff-ready implementation plan for the next chat/session.

## Problem

AI coding agents can claim work is done without running a fresh verification command. The useful public wedge for this repo is not better instructions; it is a small proof layer that forces or records fresh, inspectable evidence before an agent can say done.

The second research pass confirmed market demand and current platform fit: skills.sh has a testing category for forcing verification passes, `verification-before-completion` is a direct validating competitor with 118.6K installs, Claude Code supports lifecycle hooks including Stop, and GitHub Copilot supports repository agent instructions such as AGENTS.md plus root CLAUDE.md/GEMINI.md.

## Goals

- Make the current 0.6.0 release surface coherent across package, plugin, docs, and badges.
- Make first adoption take about 60 seconds via an `agent-done-or-not init` flow.
- Make skills.sh installation reliable instead of assuming repo-root gate scripts exist.
- Differentiate from instruction-only verification skills with inspectable receipts, hook adapters, reports, and CI integration.
- Tighten security language: promise evidence that configured checks ran, not proof of semantic correctness.

## Non-Goals

- Do not claim the tool proves code correctness.
- Do not treat local SHA-256 or local HMAC as enterprise-grade proof.
- Do not build an external ledger before CI-verified receipts exist.
- Do not add dependencies without explicit approval.
- Do not broaden into a generic AI QA platform before the proof-of-done path is polished.

## Research Summary

### Market

- skills.sh validates the category with testing skills and `verification-before-completion`.
- GitHub and Claude are making agent configuration, hooks, skills, and repo instructions first-class surfaces.
- Best messaging: `Agents can say done only after fresh proof.`
- Secondary language: `close verification debt`, `turn done into an evidence-backed claim`, `CI-style guardrails for coding agents`.

### Local Release Readiness

Confirmed blockers:

- `.claude-plugin/plugin.json` reports `0.5.0` while `package.json` reports `0.6.0`.
- `.claude-plugin/marketplace.json` reports `0.5.0` while package/changelog report `0.6.0`.
- `README.md` and `examples/install.md` still pin pre-commit examples to `rev: v0.2.0`.
- `examples/install.md` still implies npm/npx requires Bash or Git Bash on Windows, but `bin/agent-done-or-not.js` falls back to `pwsh` / `powershell`.
- `bash tests/run.sh` timed out in Windows after roughly 126 seconds; first scenarios were passing, but the suite was not green.

Confirmed coherent:

- `package.json` is `0.6.0`.
- `CHANGELOG.md` has a `0.6.0` section dated 2026-06-22.
- Local `v0.6.0` tag exists and points at `HEAD` in the prior release-agent check.
- Homebrew and Scoop manifests are pinned to `v0.6.0` and share the same tarball hash.
- `npm pack --dry-run` succeeded in the release-agent pass with cache redirected to `C:\tmp`.

### Skill Packaging

The current skill is useful but fragile as a standalone install. `skills/done-or-not/SKILL.md` tells agents to run `done-gate.sh` / `done-gate.ps1`, but a skills.sh install may install only the skill files, not repo-root gate scripts.

Preferred fixes, in order:

1. Make the skill call `npx agent-done-or-not ...` when local gate scripts are absent.
2. Or co-locate gate scripts beside the skill so the skill is self-contained.
3. Or add an explicit install/init step before using the skill.

### Security / Trust

Important framing:

- SHA-256 is a content address and tamper-evidence primitive, not trust by itself.
- Local HMAC is only meaningful if the signing key is outside the agent's control; otherwise it mainly detects accidental mutation.
- PR comments are UX, not an authority boundary.
- GitHub Checks/statuses and CI-generated artifacts should be the authoritative PR surface.
- CI verification must avoid trusting PR-modified verifier code.

## Execution Plan

### P0 - Release Hygiene

Owner model recommendation: implementer, `gpt-5.4`, medium effort.
Reviewer recommendation: release, `gpt-5.4-mini`, medium effort.

Tasks:

- [ ] Update `.claude-plugin/plugin.json` version from `0.5.0` to `0.6.0`.
- [ ] Update `.claude-plugin/marketplace.json` metadata/plugin versions from `0.5.0` to `0.6.0`.
- [ ] Update pre-commit examples in `README.md` and `examples/install.md` from `rev: v0.2.0` to `rev: v0.6.0`, unless intentionally documenting an older pin.
- [ ] Update `examples/install.md` npm/npx Windows language to mention PowerShell fallback.
- [ ] Fix, replace, or temporarily remove the broken skills.sh badge until the public page resolves.
- [ ] Add a fast smoke command documented in README or package scripts.

Acceptance:

- WHEN someone greps for `0.5.0`, the repo SHALL not contain stale release metadata for the current release.
- WHEN someone greps for `v0.2.0`, the repo SHALL not contain stale install instructions unless explicitly marked historical.
- WHEN someone reads npm/npx install docs on Windows, the docs SHALL match the current PowerShell fallback behavior.

Verification:

- `rg -n "0\.5\.0|v0\.2\.0|Git Bash|skills\.sh/b" .`
- `npm pack --dry-run` with cache redirected if needed.
- Fast smoke command, once added.
- Full `bash tests/run.sh` with a longer timeout or a documented split suite.

### P1 - 60-Second Init Flow

Owner model recommendation: implementer, `gpt-5.4`, medium effort.
Design/review recommendation: architect, `gpt-5.4`, medium effort.

Tasks:

- [ ] Add `agent-done-or-not init` to `bin/agent-done-or-not.js` or a small dedicated module.
- [ ] Detect common stacks: npm/pnpm/yarn, Python, Go, Cargo, Maven/Gradle.
- [ ] Infer default labels and commands conservatively: `test`, `build`, `lint` only when scripts/tools are present.
- [ ] Generate or patch agent instruction files with a small proof-of-done section: `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.windsurfrules`, `.clinerules` as applicable.
- [ ] Generate Claude Stop hook config when Claude Code is selected.
- [ ] Print exact next steps and one working capture command.
- [ ] Avoid overwriting existing user instructions without a visible backup or merge strategy.

Acceptance:

- WHEN `agent-done-or-not init` runs in a Node repo with `test` script, the system SHALL propose or write a `test` proof label using that script.
- WHEN no known stack is detected, the system SHALL fall back to a manual `check` label instead of inventing a command.
- WHEN existing agent instruction files exist, the system SHALL preserve unrelated content.

Verification:

- Add temp-repo tests for npm, pnpm, no-stack, and existing-instructions cases.
- Run the CLI smoke on Windows PowerShell and Bash where available.

### P2 - Reliable Skill Packaging

Owner model recommendation: implementer, `gpt-5.4`, medium effort.
Packaging/research recommendation: researcher, `gpt-5.4`, medium effort.

Tasks:

- [ ] Decide the skill execution path: `npx` fallback, self-contained scripts, or explicit init prerequisite.
- [ ] Update `skills/done-or-not/SKILL.md` so a standalone skill install cannot silently point at missing root scripts.
- [ ] Add a skill-only install simulation test.
- [ ] Update README skill section to explain what the skill installs and what still needs to be installed locally.

Recommended call:

Use `npx agent-done-or-not capture ...` as the portable skill command, with local `bash done-gate.sh` / `pwsh done-gate.ps1` as faster alternatives when the repo has been initialized.

Acceptance:

- WHEN only the skill instructions are available, the agent SHALL still have a valid command path to capture proof.
- WHEN local gate scripts are present, the skill MAY use them directly.

Verification:

- Simulate a temp repo with no `done-gate.sh` and follow the skill command.
- Simulate a temp repo after installer/init and follow the local gate command.

### P3 - Reports And PR UX

Owner model recommendation: implementer, `gpt-5.4`, medium effort.
QA recommendation: qa, `gpt-5.4-mini`, medium effort.

Tasks:

- [ ] Add `agent-done-or-not report --format markdown|html|json`.
- [ ] Include labels, commands, exit codes, freshness, SHA-256, commit SHA, dirty-tree status when available, and bypass state.
- [ ] Extend GitHub Action output with a job summary.
- [ ] Optionally add managed PR comment support, clearly marked informational.
- [ ] Keep GitHub Check/status as the authoritative gate.

Acceptance:

- WHEN a receipt exists, `report --format markdown` SHALL render a compact proof summary.
- WHEN no receipt exists or receipt failed, the report SHALL show a non-green state.
- WHEN bypass is active, the report SHALL not present the result as verified.

Verification:

- Golden-output tests for passing, failing, stale, missing, and bypass states.
- GitHub Action self-test that uploads or prints the report summary.

### P4 - CI-Verified Trust Upgrade

Owner model recommendation: security, `gpt-5.5`, high effort for design; implementer, `gpt-5.4`, high effort for implementation.
Reviewer recommendation: security, `gpt-5.5`, high effort.

Tasks:

- [ ] Extend receipt schema with `schema_version`, repo identity, commit SHA, branch/ref, dirty-tree state, command list, evidence digests, bypass flags, tool version, and generated timestamp.
- [ ] Bind receipts to commit SHA and reject replay against a different commit.
- [ ] Add CI verifier mode that uses trusted verifier code, not PR-modified scripts.
- [ ] Attach receipt JSON as artifact and print its SHA-256 in the check summary.
- [ ] Add explicit states: `missing`, `stale`, `failed`, `bypassed`, `local-only`, `ci-verified`, `ci-signed`.
- [ ] Defer external ledger until CI verification exists.

Acceptance:

- WHEN a receipt from commit A is checked on commit B, verification SHALL fail.
- WHEN verifier code is modified in a PR, CI SHALL not trust the modified verifier for protected verification.
- WHEN bypass is used, the state SHALL be visibly non-green.

Verification:

- Tests for commit mismatch, dirty-tree mismatch, malformed receipt, missing required labels, failed checks, and bypass state.
- CI security test or documented manual procedure for PR-modified verifier behavior.

## Subagent Routing For Next Chat

Use subagents only when their lane is independent and useful.

| Lane | Agent Type | Model | Effort | Reason |
|---|---|---:|---|---|
| Release metadata/docs cleanup | implementer | gpt-5.4 | medium | Small but cross-file edits need care. |
| Release readiness review | release | gpt-5.4-mini | medium | Structured checklist validation. |
| Init flow design | architect | gpt-5.4 | medium | Needs conservative UX and file ownership decisions. |
| Init implementation | implementer | gpt-5.4 | medium | CLI and temp-repo tests. |
| Skill packaging | researcher | gpt-5.4 | medium | Needs ecosystem/package behavior judgment. |
| Report/Action QA | qa | gpt-5.4-mini | medium | Verification scenarios and artifact checks. |
| Trust model / CI signing | security | gpt-5.5 | high | Correctness/security-critical boundary design. |
| Final code review | reviewer | gpt-5.5 | high | Cross-cutting release and trust changes. |

## Decisions

| Decision | Class | Call / Recommendation | Reversible? |
|---|---|---|---|
| Positioning | Mechanical | Say `fresh proof before done`, not `proves correctness`. | yes |
| P0 before new features | Mechanical | Fix release/docs/metadata drift before building `init`. | yes |
| Skill path | Taste | Prefer `npx` fallback in skill docs, with local script path after init. | yes |
| HMAC/local signing | Mechanical | Treat as local tamper evidence only, not authoritative PR proof. | yes |
| External ledger | Mechanical | Defer until CI-verified receipts exist. | yes |
| CI trust architecture | User-Challenge | Recommended: verifier logic must come from trusted base/pinned code, not PR-modified code. Confirm before implementation. | no |
| PR comments | Mechanical | Informational only; GitHub Check/status remains authoritative. | yes |

## Suggested First Commit

Make one small P0 commit only:

- plugin metadata version alignment
- stale docs refs
- npm/npx Windows docs correction
- badge handling if a clear fix exists

Then run and report:

- `rg -n "0\.5\.0|v0\.2\.0|Git Bash|skills\.sh/b" .`
- `npm pack --dry-run`
- fast smoke command if added
- full test suite or documented timeout with partial output

## Sources Consulted

- skills.sh Testing: https://www.skills.sh/topic/testing
- verification-before-completion: https://www.skills.sh/obra/superpowers/verification-before-completion
- Claude Code hooks: https://code.claude.com/docs/en/hooks
- GitHub Copilot repository instructions: https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/add-custom-instructions/add-repository-instructions
- Local files inspected: `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/done-or-not/SKILL.md`, `README.md`, `examples/install.md`, `tests/run.sh`, `bin/agent-done-or-not.js`.
