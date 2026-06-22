<!--
Internal handoff for the agent-done-or-not repo. NOT committed (left untracked).
Another agent must resume with zero chat history. Operational state, not narrative.
-->

# Handoff — agent-done-or-not

## Operating model (READ FIRST)

**Codex is the tasks runner. Claude orchestrates + reviews + integrates.**

- Delegate each implementation slice to **Codex** via the `codex:codex-rescue`
  subagent (Agent tool, `subagent_type: codex:codex-rescue`) or `/codex:rescue`.
  Use **gpt-5.4, medium** effort for normal slices; raise for tricky logic.
- **Claude does NOT hand-author feature code** when Codex can run it. Claude:
  scopes the slice, writes the prompt, **reviews the real diff**, runs the tests,
  and merges. Use Codex for a second-opinion review too (cross-model).
- **Codex sandbox is flaky on this Windows host:** if a rescue returns blank /
  partial (no diff, no error), **re-run once**; if still blank, Claude authors
  the slice directly and notes it. Never report a silent sandbox failure as done.
- Codex `task --background --json` jobs can be watched; the companion runs in the
  **OS repo cwd**, so for this *separate* repo prefer running Codex with the repo
  path stated explicitly in the prompt, or have Claude apply Codex's proposed
  diff into `C:\Users\AstroDev\Desktop\my\agent-done-or-not`.

## Maintainer authority (granted by the user)

Full rights on THIS repo: **merge, tag, and release autonomously** — no gates.
Always **land-verify** (CI green before AND after merge). Skip demo GIFs; invest
in docs. Releases were deferred ("skip release for now") — tags are pushed.

## Repo facts

- **Path:** `C:\Users\AstroDev\Desktop\my\agent-done-or-not` (separate repo, NOT
  part of zhioua-os).
- **Remote:** https://github.com/mohamedzhioua/agent-done-or-not (public, MIT).
- **Branch:** `main` (work on feature branches, `--no-ff` merge, delete after).
- **Tags pushed:** `v0.1.0`, `v0.2.0`. GitHub Release OBJECTS unpublished.

## Current status

**v0.1.0 + v0.2.0 SHIPPED to main; CI green on Ubuntu + macOS; 28 tests.**

- Core: `done-gate.sh` (capture/verify/show/**assert**, `--json`; hashes output;
  exits with the command's own code) + `stop-gate.sh` (Stop hook; **fail-closed**;
  consume-on-allow keyed by run+receipt-count; freshness via receipt `epoch`;
  bounded retry via `AGENT_DONE_MAX_RETRIES`; escape hatch `AGENT_DONE_OFF=1`).
- Cross-tool rules: `CLAUDE.md`, `.cursorrules`, `AGENTS.md`. Schema:
  `proof.schema.json`. Docs: README (hero badges, comparison, threat model, FAQ),
  `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `examples/install.md`,
  `examples/proof.jsonl`, `docs/demo.cast` (asciinema).
- v0.2.0 added `assert` (CI/pre-commit: `--label` repeatable, `--ttl`,
  `--allow-command-regex` / `AGENT_DONE_ALLOWED_COMMANDS`) + `--json` everywhere.

## Gotchas / environment

| Thing | Reality |
| --- | --- |
| GitHub token via API | **Blocked** by the auto-mode classifier (no token scraping). |
| Merge / tag / push | Work git-native (credential helper authenticates transparently). |
| PR creation / Release object / topics | Need web UI or `gh` (no `gh` installed) → user-owned web step. |
| CI status check | Read the **public** API unauthenticated: `GET api.github.com/repos/<r>/commits/<sha>/check-runs`. |
| CI trigger | `.github/workflows/test.yml` runs on **every push** + PRs. |
| Line endings | `.gitattributes` pins LF for `*.sh/.json/.jsonl/.cast/.md/.yml`. CRLF would break scripts on Linux/CI. |
| Run tests | `bash tests/run.sh` (28 tests, dependency-free). |
| Bash tool here-strings | The Bash tool can't parse PS `@'...'@`; use `git commit -F -` heredoc or a message file. |

## Next work — P1 "distribution" (chosen by user; Codex runs each slice)

Build on the now-stable `assert` + `--json` contract. Suggested order/branches:

1. **`install.sh` one-liner** — copies `done-gate.sh`/`stop-gate.sh` + rules +
   `.gitignore` line; conservative, inspectable. Branch `feat/installer`.
2. **GitHub Action** (`action.yml`) — `uses: mohamedzhioua/agent-done-or-not@v0`
   with `mode: assert`. Branch `feat/github-action`.
3. **Pre-commit hook** (`.pre-commit-hooks.yaml`, id `agent-done-assert`).
   Branch `feat/pre-commit`.
4. **Claude Code plugin** — `.claude-plugin/plugin.json` + `hooks/hooks.json`
   wiring the Stop gate; `claude plugin validate`; marketplace submission.
   Branch `feat/claude-plugin`. (Keep the plugin a WRAPPER; bash core stays canonical.)
5. **skills.sh listing** — package the proof-of-done `CLAUDE.md` rule as a SKILL
   so `npx skills add mohamedzhioua/agent-done-or-not` works; then add the live
   badge `[![skills.sh](https://skills.sh/b/mohamedzhioua/agent-done-or-not)](https://skills.sh/mohamedzhioua/agent-done-or-not)`.
   **First research skills.sh's required repo format** (what file it reads). This
   gives the "▲ Skills <installs>" badge the user liked + 20-agent distribution.

Each slice: Codex implements → Claude reviews diff + `bash tests/run.sh` (add
tests for new behavior) → push branch → verify CI (public API) → `--no-ff` merge
→ delete branch. Bump `CHANGELOG.md`; tag a release when a batch lands.

P2 (deferred): Homebrew/npm/Scoop wrappers, native PowerShell port (only after
parity tests), `awesome-claude-code` listing.

## Web-only steps for the USER (cannot be done via API here)

1. **Set GitHub topics:** `claude-code`, `codex`, `cursor`, `ai-agents`, `hooks`,
   `ci`, `verification`, `devtools`.
2. **Publish Releases** for `v0.1.0` + `v0.2.0` (notes ready at
   `.github/RELEASE_NOTES_v0.1.0.md`; write a v0.2.0 one too). Mark pre-release
   only if intended; these are stable.
3. **Social preview image** in repo Settings (optional, launch polish).
4. **Launch post** on issue #42796 + X / r/ClaudeAI when going public.

## Resume prompt

Resume in `C:\Users\AstroDev\Desktop\my\agent-done-or-not`. Confirm `git status`
clean, `main` synced, `bash tests/run.sh` = 28/28. Then pick a P1 slice above,
delegate implementation to **Codex** (`codex:codex-rescue`, gpt-5.4/medium),
review the diff, add tests, verify CI via the public check-runs API, and merge
with maintainer authority. Start with `feat/installer` unless the user redirects.
Memory file `agent-done-or-not-project` has the durable state.
