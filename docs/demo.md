# The 20-second demo

The whole pitch, start to finish: an agent says "done," the gate refuses to take
its word, and "done" only sticks once there's a fresh passing receipt.

> Terminal recording: [`docs/demo.cast`](demo.cast) — `asciinema play docs/demo.cast`.

## The arc

```text
1 │ agent: All tests pass — task complete! ✅
2 │ stop-gate: BLOCKED — no proof receipt found for this project
  │            prove your work first:
  │              bash done-gate.sh capture --label test -- <your command>
  │
3 │ agent: $ bash done-gate.sh capture --label test -- npm test
  │        FAIL  1 failing test
  │ done-gate: captured label=test run=… exit=1 sha256=8a1f…
4 │ stop-gate: BLOCKED — your most recent check FAILED (exit=1) — fix it, don't ship it
  │
5 │ agent: …fixes the bug…
6 │ agent: $ bash done-gate.sh capture --label test -- npm test
  │        PASS  12 passing
  │ done-gate: captured label=test run=… exit=0 sha256=9f2c…
7 │ stop-gate: OK — verified by a fresh passing receipt (sha256=9f2c…)
  │ agent: Done — and here's the receipt. ✅
```

No proof → blocked. Red check → blocked. Fresh green check → allowed, once.
The agent can't *say* done; it has to *show* done.

## Run it yourself

```bash
# 1. A claim with nothing behind it — the gate has no receipt to honor.
printf '{"session_id":"demo","hook_event_name":"Stop"}' | bash stop-gate.sh ; echo "exit=$?"   # → 2 (blocked)

# 2. Capture a real check. It exits with the command's OWN code, so red stays red.
bash done-gate.sh capture --label test -- sh -c 'echo "1 failing"; exit 1' ; echo "exit=$?"     # → 1

# 3. The gate still blocks: the latest receipt is a failure.
printf '{"session_id":"demo","hook_event_name":"Stop"}' | bash stop-gate.sh ; echo "exit=$?"   # → 2

# 4. Fix it, capture again — now it passes.
bash done-gate.sh capture --label test -- sh -c 'echo "12 passing"; exit 0' ; echo "exit=$?"    # → 0

# 5. The gate allows the turn to end — once, for this receipt.
printf '{"session_id":"demo","hook_event_name":"Stop"}' | bash stop-gate.sh ; echo "exit=$?"   # → 0
```

## Then make it shareable

```bash
npx agent-done-or-not report --format pr
```

```markdown
<!-- agent-done-or-not:proof -->
### ✅ Proof of Done

| | |
|---|---|
| **Status** | PASS |
| **Latest** | `npm test` · exit 0 · just now |

**Checks**
- ✅ `test` — `npm test` — exit `0` — just now — `sha256:9f2c…`

> This completion is backed by a fresh passing receipt.
<!-- agent-done-or-not:proof -->
```

Paste it into the PR. "It works" just became a receipt.
