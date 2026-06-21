# Contributing to agent-done-or-not

Thanks for helping make AI agents prove their work. This is a deliberately tiny,
dependency-free tool — contributions are very welcome, but the bar is "stays
tiny, stays trustworthy."

## Project philosophy (please read first)

Three rules shape every change here. A PR that breaks one will be asked to
change, no matter how useful the feature:

1. **Dependency-free and portable.** Only `bash`, `git`, coreutils, and one of
   `sha256sum` / `shasum` / `python` for hashing. No `jq`, no npm, no runtime.
   It must work on Linux, macOS (BSD userland), and Git Bash/MSYS on Windows.
2. **Fail closed.** The gate's entire value is that it cannot be trivially
   bypassed. When proof state is missing, empty, unparseable, or stale, the gate
   **blocks**. The only paths to exit 0 are: an explicit `AGENT_DONE_OFF=1`, a
   verified fresh passing receipt, or the anti-infinite-loop safety valve.
   If your change adds a new "allow" path, justify it explicitly in the PR.
3. **Forcing function, not a semantic oracle.** We make the agent *run* a check
   and we record proof it ran and passed. We do **not** claim to judge whether
   it was the *right* check. Keep the README's "Honest limits" honest.

## Trust model — the invariants

Any change to `stop-gate.sh` or `done-gate.sh` must preserve these. They each
have a test in `tests/run.sh`; if you change behavior, update the test and say
why in the PR.

- A **failing** check (non-zero exit) can never satisfy the gate.
- `done-gate.sh capture` always **exits with the wrapped command's own code** —
  this is what stops a red check being dressed up as green. Never swallow it.
- Freshness is judged by the **epoch recorded inside the receipt**, never file
  mtime (mtime is forgeable with `touch`).
- A receipt is **consumed** when it clears a stop; the same receipt can't clear
  a second stop. Consume persistence is **mandatory** — if it can't be written,
  block.
- `--run` and `--label` are filesystem path components and **must** be validated
  (`[A-Za-z0-9._-]`, no `..`).
- The Stop hook never enters an infinite loop: bounded by
  `AGENT_DONE_MAX_RETRIES`, then fails open with a loud warning.

## Development

```bash
git clone https://github.com/mohamedzhioua/agent-done-or-not
cd agent-done-or-not
bash tests/run.sh          # the whole suite — must be green before you push
```

There is no build step. Edit the script, run the tests.

### Adding behavior? Add a test.

`tests/run.sh` is dependency-free and runs each scenario in a throwaway
`mktemp` git sandbox. Copy an existing numbered block, assert the exit code
(`0` = allow, `2` = block), and keep it deterministic (no network, no reliance
on wall-clock beyond the explicit `sleep` freshness test).

### Style

- `set -euo pipefail` in `done-gate.sh`; `set -uo pipefail` in `stop-gate.sh`
  (it must not abort mid-evaluation — it has to reach an explicit allow/deny).
- POSIX-friendly bash. Prefer `case` over `[[ =~ ]]` for portability.
- Comment the *why*, especially around any allow/deny decision.
- Keep scripts committed with `LF` line endings (enforced by `.gitattributes`).

## Pull requests

1. Branch off `main` (e.g. `feat/...`, `fix/...`, `docs/...`).
2. Make the change + tests; run `bash tests/run.sh` (green) and CI must pass on
   Ubuntu and macOS.
3. Update docs in the same PR — README, `examples/install.md`, `proof.schema.json`,
   and `CHANGELOG.md` if behavior or knobs changed. Docs are part of done (we
   eat our own dog food here).
4. Open the PR with: what changed, which invariant(s) it touches, and how you
   verified it. Security-relevant changes should describe the threat you
   considered.

Because this tool is about trust, **changes to the gate logic get an adversarial
review** ("how would I bypass this?") before merge. New contributors: don't be
surprised if a reviewer tries to break your change — that's the whole game, and
it's how this codebase was hardened in the first place.

## Reporting a bypass / security issue

Found a way to make the gate exit 0 without a fresh passing receipt? That's the
most valuable bug you can file. Open an issue titled `bypass:` with a minimal
reproduction (a payload + the proof-dir state). If you'd rather report
privately first, say so in a short issue and we'll arrange it.

## License

By contributing you agree your work is released under the [MIT License](LICENSE).
