# v0.10.1 — Marketplace branding + cleanup

A packaging/metadata patch on top of [v0.10.0](https://github.com/mohamedzhioua/agent-done-or-not/releases/tag/v0.10.0). **No engine behavior change** — receipts, `mode: verify`, and the gates are identical.

## What changed
- **Marketplace branding** on the composite Action (`branding.icon: check-circle`, `color: green`) so it can be listed on the GitHub Marketplace with an icon.
- Removed a now-unreachable inner `mode != assert` guard in the `assert` step (already gated by the step `if:` and the reject-unsupported-mode step).
- `@v0` references in the docs now resolve via a **moving `v0` major tag** that tracks the latest `v0.x` release. For the security-critical `mode: verify` gate, keep pinning an exact tag (e.g. `@v0.10.1`) as the README recommends.

## Verify quick reference

```yaml
- uses: actions/checkout@v4
# set up your runtime + deps here (setup-node, npm ci, …)
- uses: mohamedzhioua/agent-done-or-not@v0.10.1
  with:
    mode: verify
    checks: |
      test: npm test
      build: npm run build
```

Full history in [CHANGELOG.md](../CHANGELOG.md).
