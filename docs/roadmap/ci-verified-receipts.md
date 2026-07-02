# Design: CI-verified receipts (v0.10.0, P4)

Date: 2026-07-02
Status: **ACCEPTED — §4 = option A (commands in the workflow).** Implemented in
v0.10.0. A dedicated Check Run and option B (commands in policy) remain follow-ups.
Chosen surface: **job-as-gate** (phase 1 of "both"); a dedicated Check Run is a
follow-up.

## Problem

Local receipts live in `.agent-proof/`, a workspace file the agent can write. v0.9.0
bound receipts to git state, which defeats *honest* staleness (a stale CI cache, a
green from before the last edit). It does **not** defeat an agent that *wants* to
look done: it can append a passing receipt with a matching `commit`/`exit_code`
(the README's honest boundary — equivalent to forging `exit_code:0`).

Today's GitHub Action makes this worse in one way: it runs `mode: assert`, which
**checks the receipts committed in the PR**. So CI currently trusts agent-authored
proof. That is the hole to close.

## Goal

CI must produce proof the agent could not have fabricated: **re-run the required
checks fresh from pinned verifier code, ignore any committed receipt, and expose
the result as a required gate.** Turn "a local forcing function" into "CI actually
re-verified against this commit."

## Trust model (the important part)

Three distinct things, only two of which we can protect:

1. **The gate/receipt logic** — protected. Consumers pin the Action
   (`uses: mohamedzhioua/agent-done-or-not@v0.10.0`); GitHub fetches that code from
   the pinned ref, not from the PR. A PR cannot alter how proof is generated/checked.
2. **Freshness** — protected. CI does its own `capture` (fresh run at the PR commit)
   and never reads a committed `.agent-proof/`. A pre-fabricated green receipt is
   irrelevant because CI overwrites it with its own run.
3. **The check *command* and *what counts as required*** — NOT cryptographically
   protected, and cannot be: verifying PR code means running PR code, and any config
   (workflow or policy) is itself PR-editable. The realistic protection is the same
   as every CI config: branch protection requires the check, and a reviewer sees any
   weakening in the diff. Our job is to make the check **real and visible**, not to
   prevent a human-reviewed config change.

Non-goal: defending against a malicious maintainer or an unreviewed force-push past
branch protection. That is out of scope for a lightweight tool (documented).

## §4 — THE DECISION: where do the CI check commands live?

To "run the checks fresh," CI needs the actual commands. `agent-done.json` today
stores `label` + `command_regex` (a matcher), not the command to run. Options:

- **(A) Commands in the workflow** (recommended for v1). The reusable/step config
  lists `label: command` lines; the policy's `command_regex` still validates them.
  No schema change. Commands sit in the workflow file (the pinned/CI surface),
  which is the more natural trust home. Slightly more config for the user.

    ```yaml
    - uses: mohamedzhioua/agent-done-or-not@v0.10.0
      with:
        mode: verify
        checks: |
          test: npm test
          build: npm run build
    ```

- **(B) Commands in the policy.** Add an optional `command` per required entry to
  `agent-done.json`, making it the single source of truth ("what done requires AND
  how to verify it"). CI reads and runs them. Nicer ergonomics; additive schema
  change; but the runnable command now lives in a PR-editable file (still guarded by
  the reviewer + `command_regex`, so no worse in practice).

- **(C) Both** — policy provides defaults, workflow can override.

**Recommendation: (A) for v0.10.0** (smallest, cleanest trust story), with (B) as a
fast-follow if users want policy-as-single-source. Neither is materially more
tamper-proof (see trust model §3); (A) is chosen for simplicity.

## Proposed implementation (once §4 is signed off)

1. **Receipt provenance** (additive, both engines): stamp `ci: true` when
   `GITHUB_ACTIONS`/`CI` is set, plus `ref` from `GITHUB_REF`. Add `schema_version`.
   Backward compatible (readers ignore unknown fields; absence ⇒ local).
2. **Action `mode: verify`**: read `checks`, for each `label: command` run
   `done-gate.sh capture --label <label> -- <command>` fresh (from the pinned
   engine), then `assert` the policy/labels. Fail the job on any capture/assert
   failure (**job-as-gate**). Upload `.agent-proof/` as an artifact; print each
   receipt SHA + the commit in the job summary. Keep `mode: assert` as-is.
3. **Reusable workflow template** in `docs/ci-templates/` + a README section:
   "make `proof-of-done` a required status check."
4. **Docs**: threat-model update — CI-verified receipts close the fabrication gap
   for same-repo PRs; fork PRs get a documented caveat (read-only token can't post
   checks; job still fails, which is enough for job-as-gate).
5. **Tests**: provenance stamping (bash + PS parity); `verify` mode via the
   action-selftest workflow (success + a weakened-command-caught case); a local
   simulation of the fresh-capture-then-assert flow.

## Acceptance

- WHEN a PR commits a hand-written passing `.agent-proof/` but the real check fails,
  CI `verify` SHALL fail the job (fresh run overrides the committed receipt).
- WHEN every required check passes fresh in CI, the job SHALL pass and the receipt
  artifact + SHA SHALL be published.
- WHEN the verifier is referenced by pinned tag, the gate logic SHALL come from that
  tag, not the PR.

## Decision (resolved)

**§4 = option A** (commands in the workflow) for v0.10.0. Option B (commands in
policy, single source of truth) is a documented fast-follow; the two are not
materially different on tamper-resistance (see trust model §3), so A wins on
simplicity. Everything else follows the already-agreed job-as-gate design.
