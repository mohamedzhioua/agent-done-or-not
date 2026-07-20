# PR Receipts (`review-pr`)

> Separate **RE-EXECUTED** from **ASSERTED** claims in AI-authored pull requests.
> Re-execute the project's real test/lint/build commands, hash the output, and
> print a short receipt — instead of adding another speculative LLM review
> comment. A green re-run proves the command passed here and now, **not** that the
> PR is correct — so the receipt never says "verified."

`review-pr` is the reviewer-side companion to `capture`/`assert`: it takes an
AI-authored PR's description, parses the testable claims out of it, resolves the
project's **real** commands from its manifests, re-executes them, and prints a
receipt. No LLM, zero dependencies.

## How it works

1. **Claim parse** — conservatively scan the PR description (and, with
   `--commits`, the commit messages) for testable claims: "tests pass", "lint
   clean", "build succeeds". Recognized-but-not-re-executable assertions ("no
   breaking changes", "handles edge cases") are surfaced separately, and vague
   phrasing ("should be good to merge") goes to an explicit **unparsed** bucket —
   never guessed at.
2. **Command resolve** — auto-detect the project's real command for each claimed
   category from its manifest. v1 covers three ecosystems (first match wins):

   | manifest | test | lint | build |
   |---|---|---|---|
   | `package.json` | `npm test` | `npm run lint` | `npm run build` |
   | `pyproject.toml` | `pytest` | `ruff check .` | — |
   | `go.mod` | `go test ./...` | `go vet ./...` | `go build ./...` |

   Node commands are gated on the matching `test`/`lint`/`build` script being
   present. A claimed category with no resolvable command is reported as
   **asserted** (unverified), never silently skipped. (Rust/Cargo, Make, and a
   config override file are future work.)
3. **Re-execute** — run each resolved command against the checked-out code,
   capture stdout+stderr, sha256 the log, and record the command's own exit code.
   Optional per-command timeout via `AGENT_DONE_PR_TIMEOUT` (default 300s, where a
   `timeout` binary is available).
4. **Receipt** — print the RE-EXECUTED / ASSERTED / UNPARSED block (human or
   `--json`). Exits **non-zero** if any re-executed claim failed, so it can gate a
   CI check.

### Example

```
# PR Receipts

RE-EXECUTED (2 claim(s) re-run)
  PASS "Tests pass"     -> npm test      exit=0  sha256=02098f4d5280
  FAIL "lint is clean"  -> npm run lint  exit=1  sha256=10ec55f5a41e

ASSERTED (2 claim(s), no re-executable evidence)
  ?    "build succeeds"       -- no build command resolved from the project's manifests
  ?    "No breaking changes"  -- no command maps to this claim

UNPARSED (1 claim-like phrase(s), not confidently matched)
  .    "Should be good"
```

## Usage

```bash
# local pre-review: sanity-check your own branch's claims before opening the PR
done-gate.sh review-pr --body pr-description.md

# also fold in commit messages (base..HEAD), machine-readable
done-gate.sh review-pr --body pr-description.md --commits --base origin/main --json

# from a pipe
gh pr view 142 --json body -q .body | done-gate.sh review-pr --body -
```

Never the word "VERIFIED": the output labels are RE-EXECUTED / ASSERTED /
UNPARSED. A green re-run proves the command passed, not that the change is
correct.

## Trust model — re-execution is code execution

`review-pr` re-executes **the PR's own code** using the project's own commands.
This is not sandboxed by default; it runs whatever `npm test` (etc.) does, with
whatever permissions the invoking process has. Be honest about that:

- **The command re-run is never derived from the PR text.** The PR body only
  selects *which category* (test/lint/build) is claimed; the actual command comes
  from `done-gate.sh`'s fixed per-ecosystem resolution table. A PR cannot inject a
  command through its description.
- **Local pre-review** — you are running your own uncommitted branch; the trust
  boundary is the one you already accept every time you run your own test suite.
- **CI check (recommended for untrusted PRs)** — run inside the CI provider's own
  PR-execution sandbox. Trigger on the **`pull_request`** event, **never
  `pull_request_target`**, and give the job **no secrets** it doesn't need — an
  untrusted fork must not reach your credentials. `review-pr` adds no sandbox of
  its own; it inherits whatever isolation the CI job already has.
- **Never recommended:** running `review-pr` against an untrusted fork's PR on a
  developer's own machine with full credentials.

## GitHub Action

```yaml
# .github/workflows/pr-receipts.yml
name: PR Receipts
on: pull_request            # NOT pull_request_target — see the trust model above
permissions:
  contents: read            # least privilege; add pull-requests: write only if pr-comment
jobs:
  receipts:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}   # the PR's code
      # install the project's deps here (npm ci / pip install / go mod download)
      - uses: mohamedzhioua/agent-done-or-not@v0.13.1
        with:
          mode: review-pr
          pr-body: ${{ github.event.pull_request.body }}
        env: {}             # no secrets in scope for untrusted-PR re-execution
```

The job fails if a re-executed claim did not pass. Set `pr-comment: "true"` (and
`permissions: pull-requests: write`) to upsert the receipt as a sticky PR comment.

## Coverage & limitations

Coverage is reported, never hidden — but it is deliberately narrow:

- **A missing toolchain reads as a failed re-run.** If a claimed command resolves
  but the tool isn't installed here (`pytest`/`go`/`ruff` absent), the re-run
  exits non-zero and the claim shows as failed — "could not be substantiated in
  this environment", not "the claim is false". Run `review-pr` where the project's
  toolchain is actually set up (e.g. after `npm ci` / `pip install` in CI).
- **Per-command timeout** needs a `timeout` (or `gtimeout`) binary on the bash
  engine (`AGENT_DONE_PR_TIMEOUT`, default 300s); where neither exists a hanging
  re-run is unbounded. The PowerShell engine always bounds it.
- **Claim parsing is conservative pattern-matching**, not NLP. The ASSERTED and
  UNPARSED buckets recognize a fixed set of shapes; a PR asserting several distinct
  non-re-executable things is summarized, not enumerated one-for-one. Precision
  over recall is the explicit bias — a phrase it can't confidently match is
  surfaced as UNPARSED, never force-matched.

## Non-goals

- **Not a code reviewer.** It does not read the diff for logic, style, or design —
  it checks whether *stated* claims are backed by re-executed evidence.
- **No LLM.** Claim parsing is pattern-based; the receipt never depends on a model.
- **Not a correctness oracle.** A green re-run proves the command passed, not that
  the change is right — and it cannot tell you the check was the *right* check.
- **Not a security scanner.** Pair it with a dedicated scanner if that's the goal.
