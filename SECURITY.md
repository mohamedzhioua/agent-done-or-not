# Security Policy

`agent-done-or-not` is a trust tool: its whole value is that an AI agent cannot
trivially mark work "done" without proof. So **a bypass is a security bug**, and
it's the most valuable thing you can report.

## Supported versions

The latest tagged release and `main` are supported. Older tags are not patched.

## What counts as a vulnerability

- A way to make `stop-gate.sh` exit 0 (allow a stop) without a fresh, passing,
  unconsumed receipt — outside the documented escape hatch (`AGENT_DONE_OFF=1`)
  and the anti-infinite-loop safety valve (`AGENT_DONE_MAX_RETRIES`).
- A way to make `done-gate.sh assert` report success when a required label has no
  fresh passing receipt.
- Making `capture` record a passing (`exit_code: 0`) receipt for a command that
  actually failed.
- Making the Action's `mode: verify` report success when a freshly re-run check
  actually failed — for example, a committed `.agent-proof/` receipt influencing
  the verdict instead of being ignored.
- Path traversal or command injection via `--run` / `--label` / a crafted
  payload or ledger.

Out of scope (documented limits, see the README threat model): choosing a weak
check yourself; an agent that can already freely rewrite files in `.agent-proof/`
(CI `mode: verify` re-runs the checks, so a committed forgery is ignored there);
a weakened but human-reviewed CI config or required-check setting; and fork PRs
being unable to post a Check Run / comment (the verify job still fails on a red
check, which is enough to gate).

## How to report

- **Low/medium severity:** open a public issue titled `bypass:` with a minimal
  reproduction — the Stop payload (or `assert` args) plus the `.agent-proof/`
  state that triggers it. Clear repros get fixed fastest.
- **High severity / sensitive:** open a short issue asking to discuss privately
  (no details), and we'll arrange a private channel before disclosure.

Please don't open PRs that weaken `set -euo`/`set -uo` handling, the fail-closed
paths, or the consume/freshness logic without a discussion first — those are the
load-bearing invariants (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Response

This is a small open-source project maintained on a best-effort basis. Expect an
acknowledgement within a few days; fixes for confirmed bypasses are prioritized
over features.
