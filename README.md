# agent-done-or-not

[![Works with Claude Code · Cursor · Codex](https://img.shields.io/badge/works_with-Claude_Code_·_Cursor_·_Codex-black?style=for-the-badge&logo=anthropic&logoColor=white)](#install-60-seconds)
[![GitHub stars](https://img.shields.io/github/stars/mohamedzhioua/agent-done-or-not?style=for-the-badge&logo=github&color=black)](https://github.com/mohamedzhioua/agent-done-or-not/stargazers)
[![Agent Skill](https://img.shields.io/badge/agent_skill-done--or--not-black?style=for-the-badge)](https://skills.sh/mohamedzhioua/agent-done-or-not)

[![CI](https://github.com/mohamedzhioua/agent-done-or-not/actions/workflows/test.yml/badge.svg)](https://github.com/mohamedzhioua/agent-done-or-not/actions/workflows/test.yml)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Agent_Done_Or_Not-2ea44f?logo=github)](https://github.com/marketplace/actions/agent-done-or-not)
[![npm](https://img.shields.io/npm/v/agent-done-or-not?logo=npm)](https://www.npmjs.com/package/agent-done-or-not)
[![Release](https://img.shields.io/github/v/tag/mohamedzhioua/agent-done-or-not?label=release)](https://github.com/mohamedzhioua/agent-done-or-not/releases)
![Dependencies: none](https://img.shields.io/badge/dependencies-none-brightgreen.svg)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Your AI agent just said "Done ✅" — but did it verify?** This one-file gate
forces it to record fresh evidence before it can declare success. Works
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

## Which tool does what?

These complementary tools cover different parts of the agent trust boundary:

| tool | job |
|---|---|
| agent-done-or-not | evidence capture, done-gating, claim auditing, PR verification |
| proofguard | repo-policy guards |
| rulesentry | rules-file supply-chain security |

## Install (60 seconds)

From the repo you want to protect:

```bash
npx agent-done-or-not init --yes
```

Prefer to inspect first? Use `npx agent-done-or-not init --dry-run`, or use the
manual two-file install in **[examples/install.md](examples/install.md)**.

Then wire the rule + hook for your tool — see **[examples/install.md](examples/install.md)**.

- **Claude Code** → drop in `CLAUDE.md` + the `Stop` hook = hard enforcement.
  `init --claude-hook` (alias `--claude`) also copies the gate scripts into the
  repo, so the generated hook resolves instead of pointing at files that don't
  exist.
- **Cursor** → drop in `.cursorrules`.
- **Codex / others** → drop in `AGENTS.md`.

### Agent Skill

```bash
npx skills add mohamedzhioua/agent-done-or-not
# or target just this skill:
npx skills add mohamedzhioua/agent-done-or-not --skill done-or-not
```

Installs the proof-of-done rule as a skill for Claude Code / Codex / other
agents (the [`skills` CLI](https://github.com/vercel-labs/skills) auto-discovers
`skills/done-or-not/SKILL.md`). A skill-only install gives the agent
instructions, not repo-root gate scripts; use `npx agent-done-or-not capture ...`
from the skill, or run `agent-done-or-not init` / the installer first to add local
`done-gate.*` scripts and hook config.

The skill is discoverable in the [skills.sh](https://www.skills.sh/) directory —
running the command above is what surfaces it there (the directory ranks skills
by anonymous install telemetry).

### npm / npx

Run the gate without cloning — handy in a CI step, an npm script, or a
skill-only install:

```bash
npx agent-done-or-not capture --label test -- npm test
npx agent-done-or-not assert --label test --ttl 3600
```

The npm wrapper uses the bundled Bash engine when Bash is available, and falls
back to the bundled PowerShell engine on Windows.

You can also wire the Stop hook itself through npx, with no vendored scripts
needed:

```bash
npx agent-done-or-not stop-gate
```

Point your harness's Stop/finish hook at that command instead of a local
`stop-gate.sh` / `stop-gate.ps1` file — it pipes the hook payload on stdin and
keeps the engine (and any policy file) beside it.

Fast local smoke check for the npm wrapper:

```bash
npm run smoke
```

### Homebrew / Scoop

Install a global `agent-done-or-not` launcher:

```bash
# macOS / Linux
brew install mohamedzhioua/tap/agent-done-or-not
```

```powershell
# Windows (native PowerShell launcher)
scoop bucket add agent-done-or-not https://github.com/mohamedzhioua/scoop-bucket
scoop install agent-done-or-not
```

The pinned formula and manifest live in [`packaging/`](packaging/); see
[`packaging/README.md`](packaging/README.md) for publishing them to a tap/bucket.

### Windows (native PowerShell — no bash needed)

`done-gate.ps1` is a native port of the engine with identical behavior and an
identical receipt format. It runs on Windows PowerShell 5.1 and PowerShell 7+
with built-ins only — no bash required:

```powershell
pwsh done-gate.ps1 capture --label test -- your-test-command
pwsh done-gate.ps1 assert --label test --ttl 3600
```

Receipts written by `done-gate.ps1` and `done-gate.sh` are interchangeable.

### GitHub Action

Use the composite action to gate a workflow job on receipts created earlier in
the same checkout:

```yaml
- uses: actions/checkout@v4
- uses: mohamedzhioua/agent-done-or-not@v0
  with:
    mode: assert
    labels: "test build"
    ttl: "3600"
    pr-comment: "true"   # optional: upsert a sticky proof comment on the PR
```

Run `actions/checkout` first, then produce receipts earlier in the job with
`bash done-gate.sh capture` before the action asserts them. With
`pr-comment: "true"` on a pull request, the action upserts a single sticky
proof comment (✅/❌ status + the gate output); it never changes the job's
pass/fail — `assert` still decides that.

#### `mode: verify` — CI re-runs the checks (don't trust committed receipts)

`mode: assert` trusts the receipts the branch committed. `mode: verify` does
**not**: it ignores any committed `.agent-proof/`, re-runs your real checks
**fresh** from the pinned Action code, and fails the job on a red result. The
proof it trusts is the one CI just produced — so an agent can't turn the gate
green by committing a fabricated passing receipt.

```yaml
- uses: actions/checkout@v4
# set up your runtime + deps here (setup-node, npm ci, …)
- uses: mohamedzhioua/agent-done-or-not@v0.10.0
  with:
    mode: verify
    checks: |          # one "label: command" per line; each runs via bash -c
      test: npm test
      build: npm run build
```

Each fresh receipt's SHA-256 and the verified commit are printed to the job
summary, and `.agent-proof/` is uploaded as a build artifact.

**Make it a required check.** Copy
[`docs/ci-templates/github-verify.yml`](docs/ci-templates/github-verify.yml) to
`.github/workflows/proof-of-done.yml`, then in **Settings → Branches → Branch
protection → Require status checks to pass before merging** add the
**`proof-of-done`** check. A red re-run now blocks merge.

**Pin the tag.** `uses: …@v0.10.0` makes GitHub fetch the verifier from that
tag, not from the PR, so a PR cannot change how proof is generated or checked.
The check *commands* live in the workflow (a PR-editable file, like any CI
config) — a reviewer sees any weakening in the diff, and branch protection keeps
the check required. Fork PRs run with a read-only token; the job still fails on a
red check, which is all job-as-gate needs. See the
[threat model](#how-it-can--and-cant--be-fooled-threat-model).

### Claude Code plugin

Install the thin Claude Code plugin wrapper:

```bash
claude plugin marketplace add mohamedzhioua/agent-done-or-not
claude plugin install agent-done-or-not
```

The plugin keeps the bash core canonical at the repo root and only wires
`stop-gate.sh` as Claude Code's `Stop` hook for hard enforcement. You still drop
the `CLAUDE.md` rule into the protected repo for the agent-facing instruction.

## Use

```bash
# Run any check through the gate — it exits with the command's own code:
bash done-gate.sh capture --label test -- npm test

# Inspect the receipts:
bash done-gate.sh show

# Render a compact proof summary:
npx agent-done-or-not report --format markdown
```

```json
{"label":"test","command":"npm test","exit_code":0,"sha256":"9f2c…","log":".agent-proof/…/test.log","at":"2026-07-16T19:44:00Z","epoch":1784231040,"session":"","commit":"0123456789abcdef0123456789abcdef01234567","tree":"89abcdef0123456789abcdef0123456789abcdef","dirty":false,"schema_version":2,"ci":false,"ref":"","repo":"https://github.com/example/project.git","subject":"Add verification tests","producer":"done-gate.sh@0.11.0","verifier":"","host_os":"linux","disposition":"reexecuted"}
```

The v2 evidence envelope adds repository and commit identity (`repo`, `subject`),
producer and verifier identity (`producer`, `verifier`), the capture environment
(`host_os`, one of `linux`/`darwin`/`windows`/`unknown` — identical across the
bash and PowerShell engines on the same machine), and the evidence `disposition`.
`capture` always writes `disposition: "reexecuted"` because it runs the recorded
command; `assert`, `verify`, and the Stop gate reject any v2 receipt whose
`disposition` is anything else, so an asserted claim can never pass as a re-run.

See [`examples/proof.jsonl`](examples/proof.jsonl) for a full ledger sample.

### Pre-commit hook

Add this to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/mohamedzhioua/agent-done-or-not
    rev: v0.8.0
    hooks:
      - id: agent-done-assert
```

This runs `done-gate.sh assert` before every commit and **blocks** unless a fresh
passing proof-of-done receipt exists in `.agent-proof/`. Pass extra options via
`args:`, for example:

```yaml
      - id: agent-done-assert
        args: [--label, test, --ttl, "3600"]
```

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

## Required checks (policy)

A rule in `CLAUDE.md` makes the agent *run something*. A **policy** makes it run
the **right** things. Drop an `agent-done.json` at your repo root:

```json
{
  "required": [
    { "label": "test",  "command_regex": "(npm|pnpm|yarn) (run )?test|pytest" },
    { "label": "build", "command_regex": "(npm|pnpm) run build" }
  ],
  "ttl": 3600
}
```

Now `assert` (with no `--label`) requires a **fresh, passing** receipt for every
listed label *and* checks that each was produced by a command matching its
`command_regex` — so `true` or `echo ok` can't satisfy a `test` requirement:

```bash
bash done-gate.sh assert          # reads agent-done.json automatically
bash done-gate.sh assert --json   # adds a "policy" field
```

Resolution order is **explicit `--label` → policy file → most-recent receipt**;
pass `--no-policy` to force the legacy path, or `--policy <file>` to point
elsewhere. Receipts captured in separate runs still count (policy mode searches
all runs per label). Scaffold one from your detected stack with
`npx agent-done-or-not init --policy`. The format is documented in
[`policy.schema.json`](policy.schema.json).

**Wrong-check warning.** Labels carry a strength taxonomy (strong: `test`,
`build`, `typecheck`, `e2e`, `smoke`…; weak: `lint`, `format`, `manual`…). If the
only passing evidence is a weak check, `assert` and `report` print an advisory
`latest proof is lint-only — this may not verify the requested behavior`. It's a
nudge, never a blocker — the exit code is unchanged.

## Share the proof

Turn a ledger into something pasteable. `report` leads with a human card; the
`pr` format is a sticky, marker-wrapped comment for pull requests:

```bash
npx agent-done-or-not report                 # card + table
npx agent-done-or-not report --format pr     # paste into a PR / issue
```

```markdown
### ✅ Proof of Done

| | |
|---|---|
| **Status** | PASS |
| **Latest** | `npm test` · exit 0 · 2m ago |

**Checks**
- ✅ `test` — `npm test` — exit `0` — 2m ago — `sha256:9f2c…`
```

In CI, the [GitHub Action](#github-action) can post this as a sticky PR comment —
set `pr-comment: "true"`.

## Audit the agent's claims

`capture` records what actually ran; **`audit`** checks what the agent *said*
against those receipts. It reads the agent's claims — from structured markers it
was told to emit, with a conservative transcript-heuristic fallback — and diffs
each against the ledger:

```bash
# The agent emits a marker per claim in its summary:
#   <agent-done:claim label="test" exit="0" />
done-gate.sh audit --transcript summary.md
```

```text
test          marker   BACKED             claimed[exit=0] recorded[exit=0 sha=9f2c…]
integration   marker   UNBACKED           claimed[exit=0] recorded[— asserted, never run]
lint          marker   MISREPORTED        claimed[exit=0] recorded[exit=1]
done-gate: audit FAIL — 1 unbacked, 1 misreported, 0 integrity-mismatch
```

Per-claim verdicts: **BACKED** · **UNBACKED** (asserted, never run) ·
**MISREPORTED** (claimed exit 0, recorded non-zero) · **INTEGRITY_MISMATCH**
(claimed hash ≠ recorded hash) · **UNPARSED** (claim-shaped text with no bindable
label — surfaced, never counted as backed). It exits non-zero on any unbacked,
misreported, or integrity-mismatched claim, and prints `--json` for gates. Only
execution receipts can back a claim; a hash mismatch is reported as a mismatch,
never as "TAMPERED" (a hash proves *what* differs, not *who* changed it).

For subagents, **`subagent-audit.sh`** is a SubagentStop hook that audits a
subagent's summary before the parent trusts it — blocking only on a real finding
and failing open otherwise. See **[`docs/markers.md`](docs/markers.md)** for the
paste-ready marker contract, the agent instruction snippet, and the hook wiring.

## How it works

1. **`done-gate.sh capture`** runs your check, streams its output, and appends a
   receipt to `.agent-proof/<run>/ledger.jsonl` — including the git `commit`
   (full HEAD SHA), `tree`, and `dirty` state at capture time (empty/`false`
   outside a git repo). It exits with the command's own exit code.
2. **`stop-gate.sh`** is a Stop-event hook. It blocks the agent from ending its
   turn unless the most recent receipt is:
   - **passing** (a red check can never mean "done"),
   - **fresh** — judged by the epoch recorded *inside* the receipt (not file
     mtime, which `touch` could forge); older than `AGENT_DONE_TTL` (default 1h)
     is rejected, so it never honors yesterday's ledger,
   - **not already used** to clear a previous stop (every completion needs its
     own proof), and
   - **policy-satisfying** — if `agent-done.json` exists, the gate requires a
     fresh passing receipt for *every* required label, not just the latest
     receipt of any label (parity with `assert`). It **fails closed** if the
     policy can't be evaluated.
3. **State drift is flagged, not silently ignored.** `assert`, `report`, and
   the Stop gate compare the receipt's recorded commit/tree/dirty state to the
   current one. A mismatch — the classic "green receipt from
   before your last edit" or stale-CI-cache gap — prints an advisory warning by
   default; set `AGENT_DONE_BIND_STATE=1` to turn that warning into a hard
   failure/block.

EXECUTION receipts are the re-run evidence stored in `ledger.jsonl` with
`disposition=reexecuted` ([`proof.schema.json`](proof.schema.json)). CLAIM/VERDICT
records (`asserted`/`unparsed`) live in a **separate file**
([`claim.schema.json`](claim.schema.json)), so they are structurally distinct from
execution proof. An asserted claim can never satisfy `assert`, `verify`, or the
Stop gate: those readers consume only `ledger.jsonl`, and they additionally fail
closed on any `schema_version>=2` line whose `disposition` is not `reexecuted`.

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

Precisely: the SHA-256 is proof of exactly what the recorded command printed.
The receipt as a whole is a **verification receipt** — evidence that the
configured check ran and passed against a specific commit — not a proof of
semantic correctness or that the task is actually finished. You still have to
pick a command that verifies what you claim.

**It stops these:**
- Claiming "done" with no check run → blocked (no receipt).
- A failing check dressed up as success → blocked (`capture` records and exits
  with the real non-zero code).
- Re-using an old green run → blocked (receipts are consumed; freshness uses the
  epoch *inside* the receipt, so `touch` won't refresh it).
- Malformed/empty proof state to slip through → blocked (the gate **fails
  closed**).
- An infinite block loop → bounded safety valve (`AGENT_DONE_MAX_RETRIES`).
- Running the wrong class of check → constrain it with an `agent-done.json`
  policy (per-label `command_regex`) or `assert --allow-command-regex`. A policy
  that is present but unparseable **fails closed** — it never silently degrades
  to the most-recent receipt.
- **A fabricated receipt committed in a PR** → blocked in CI with
  [`mode: verify`](#mode-verify--ci-re-runs-the-checks-dont-trust-committed-receipts):
  CI ignores committed receipts and re-runs the checks **fresh** from the pinned
  Action code, so a hand-written green can't survive a red re-run. Make
  `proof-of-done` a required status check and a red result blocks merge.

**It does NOT claim to stop these** (out of scope by design):
- Choosing a *weak* check (an empty test suite "passes"). You pick the command;
  pair it with `--allow-command-regex` and real tests.
- An agent that rewrites the *local* ledger files by hand. If your agent can
  freely edit `.agent-proof/` it can forge anything locally — treat the ledger as
  you would any workspace file. (`verify --sha` lets a second party confirm a
  specific hash; `mode: verify` in CI re-runs the checks so a committed forgery is
  ignored there.)
- **A weakened CI config.** `mode: verify` re-runs the check *commands*, but
  those commands (and which check is *required*) live in the workflow — a
  PR-editable file, like any CI config. This is not cryptographically
  protected and can't be: verifying PR code means running PR code. The realistic
  defense is the same as every CI setup — branch protection keeps the check
  required, and a reviewer sees any weakening in the diff. Pinning the Action by
  tag protects the gate *logic*, not the *commands*.
- **Fork PRs post no checks, but still gate.** A pull request from a fork runs
  with a read-only `GITHUB_TOKEN`, so the Action can't post a PR comment or a
  Check Run. The verify **job** still runs and still fails on a red check, which
  is all job-as-gate needs — the required status check turns red and blocks merge.
- A malicious maintainer, or an unreviewed force-push past branch protection.
  Out of scope for a lightweight tool.
- Hard enforcement on harnesses without a stop hook (Cursor): there the rule is
  advisory, but every receipt is still recorded for you and CI to audit.
- **Async / fire-and-forget work.** A receipt captures the command's exit state
  at the moment it exits — not background work that finishes later. If the
  real check is asynchronous, use a command that blocks until it's done (poll,
  wait, or a synchronous health check); otherwise don't claim done from it.
- **A stale green from before your last edit.** This is why receipts are now
  bound to the git commit/tree at capture time (see [How it
  works](#how-it-works)) — a receipt captured against old code, including a
  cached CI green, no longer looks identical to a fresh one. Set
  `AGENT_DONE_BIND_STATE=1` to make that drift a hard failure instead of a
  warning.

Report a bypass — see [SECURITY.md](SECURITY.md). It's the most valuable issue
you can file.

## Escape hatch

```bash
export AGENT_DONE_OFF=1   # disable the gate
```

## FAQ

**Does it need Node / Python / jq?** No. Just `bash`, `git`, and one of
`sha256sum` / `shasum` / `python` for hashing.

**Windows?** Fully supported natively. `done-gate.ps1` and `stop-gate.ps1`
are native PowerShell ports (PS 5.1 + PS 7+, no bash required). Receipts
are interchangeable between the bash and PowerShell engines. CI (`test.yml`)
runs the PowerShell parity suite on both **Windows PowerShell 5.1** and
**PowerShell 7+** on every push.

**What does `AGENT_DONE_BIND_STATE=1` do?** Turns the advisory git-state-drift
warning (receipt commit/tree/dirty doesn't match the current one) into a hard
failure for `assert` and a hard block for the Stop gate, and requires the receipt
to carry a commit binding at all. Off by default so it doesn't break off-VCS or
detached-HEAD usage. It defends against **honest** staleness — a stale CI cache
or a green from before your last edit — not a tampered ledger: an agent that can
write the ledger can also write a matching `commit`, which is the same trust
boundary as forging `exit_code:0` (see the threat model).

**Won't it get my agent stuck?** No — after `AGENT_DONE_MAX_RETRIES` consecutive
blocks it fails open with a loud warning, and `AGENT_DONE_OFF=1` disables it.

**Is the receipt private?** Yes — `.agent-proof/` is local and gitignored; it's
never committed. Keeping it ignored also matters for the git-state check above:
if `.agent-proof/` weren't ignored, writing a receipt would dirty the tree it's
supposed to be describing.

**What's the difference between `capture` and `assert`?** `capture` *runs* a
check and records proof (use it in the agent loop). `assert` *checks the ledger*
without running anything (use it in CI / pre-commit).

## Credits

Extracted and sharpened from the evidence/verify-gate layer of
**[zhioua-os](https://github.com/zhioua-os)**, an AI engineering OS for coding
agents ("replace trust with evidence"). MIT licensed — fork it, ship it.
