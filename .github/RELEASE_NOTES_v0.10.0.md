# v0.10.0 — CI-verified receipts

Until now the GitHub Action ran only `mode: assert`, which **trusts the receipts
the branch committed**. So an agent that wants to look done could commit a
fabricated passing receipt and CI would believe it. **v0.10.0 adds `mode: verify`**:
CI ignores committed receipts, **re-runs your checks fresh** from the pinned
Action code, and fails the job on a red result. Make `proof-of-done` a required
status check and a lie can't merge.

## Highlights

- **Action `mode: verify`.** List the checks to re-run, one `label: command` per
  line, in a `checks:` block. The Action re-runs each one **fresh** at the PR
  commit (via `bash -c`), ignoring any committed `.agent-proof/`, and fails the
  job on any red check (**job-as-gate**). Each fresh receipt's SHA-256 and the
  verified commit are written to the job summary, and `.agent-proof/` is uploaded
  as an artifact. `mode: assert` is unchanged.

  ```yaml
  - uses: actions/checkout@v4
  # set up your runtime + deps here (setup-node, npm ci, …)
  - uses: mohamedzhioua/agent-done-or-not@v0.10.0
    with:
      mode: verify
      checks: |
        test: npm test
        build: npm run build
  ```

- **Receipt provenance.** `capture` now stamps `schema_version`, `ci` (`true`
  when `GITHUB_ACTIONS`/`CI` is set), and `ref` (from `GITHUB_REF`) into every
  receipt, so a CI-produced receipt is distinguishable from an agent-committed
  one. Additive, backward compatible, and byte-identical across the bash and
  PowerShell engines.

- **Required-check template.** Copy
  [`docs/ci-templates/github-verify.yml`](../docs/ci-templates/github-verify.yml)
  to `.github/workflows/proof-of-done.yml`, then add `proof-of-done` under
  **Settings → Branches → Require status checks to pass before merging**.

## Security

- **Closes the committed-forgery gap for same-repo PRs.** A hand-written green
  receipt cannot survive a red re-run — CI overwrites it with what actually
  happened.
- `verify` asserts by **explicit label against the pinned CI-scoped run** (never
  the mutable `latest` pointer, never policy mode), and captures each check with
  **stdin closed**, so a forged-`epoch` committed receipt, a mid-run `latest`
  repoint, or a stdin-reading check cannot slip a red past the gate. The flow
  lives in a unit-tested `ci-verify.sh`.
- **Documented limits.** Pinning the Action by tag protects the gate *logic*, not
  the check *commands* — those live in the workflow, a PR-editable file, so a
  reviewer + branch protection are the defense (verifying PR code means running PR
  code). Fork PRs run read-only and can't post a Check Run, but the verify job
  still fails on red, which is all job-as-gate needs. See the README threat model
  and [SECURITY.md](../SECURITY.md).

## Positioning

The receipt is a **verification receipt** — evidence that the configured check
ran and passed against a specific commit. `mode: verify` makes CI produce that
evidence itself instead of trusting the branch's copy. It is still not proof of
semantic correctness: you choose a command that verifies what you claim.

Full details in [CHANGELOG.md](../CHANGELOG.md).
