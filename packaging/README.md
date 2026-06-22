# Packaging

Distribution manifests for `agent-done-or-not`. The bash engine
(`done-gate.sh` + `stop-gate.sh`) is canonical; everything here is a thin
wrapper that fetches a tagged source tarball and exposes an
`agent-done-or-not` launcher on `PATH`.

Both manifests are pinned to a release tarball and its SHA-256. **When you cut
a new release, bump `version`, the `url`, and the `sha256`/`hash` in both files
to the new tag.** Compute the hash with:

```bash
curl -sL https://github.com/mohamedzhioua/agent-done-or-not/archive/refs/tags/vX.Y.Z.tar.gz \
  | sha256sum
```

## Homebrew (`homebrew/agent-done-or-not.rb`)

macOS and Linux. Publishing is a one-time tap setup, then a copy per release:

1. Create a public repo `mohamedzhioua/homebrew-tap`.
2. Copy this file to `Formula/agent-done-or-not.rb` in that repo and push.
3. Users install with:

   ```bash
   brew install mohamedzhioua/tap/agent-done-or-not
   ```

Validate before publishing (requires a local Homebrew):

```bash
brew install --build-from-source ./packaging/homebrew/agent-done-or-not.rb
brew test  agent-done-or-not
brew audit --strict --new ./packaging/homebrew/agent-done-or-not.rb
```

## Scoop (`scoop/agent-done-or-not.json`)

Windows. The engine runs on bash, so users need Git for Windows
(`scoop install git`) on `PATH`. Publishing:

1. Create a public repo `mohamedzhioua/scoop-bucket`.
2. Copy this file to `bucket/agent-done-or-not.json` in that repo and push.
3. Users install with:

   ```powershell
   scoop bucket add agent-done-or-not https://github.com/mohamedzhioua/scoop-bucket
   scoop install agent-done-or-not
   ```

Validate before publishing (requires a local Scoop):

```powershell
scoop install ./packaging/scoop/agent-done-or-not.json
agent-done-or-not capture --label smoke -- cmd /c "exit 0"
```

> Publishing to a tap/bucket is an external-registry step — it is intentionally
> left to a maintainer with push access to those repos.
