#!/usr/bin/env bash
# stop-gate.sh — block "done" until it's proven.
#
# A Stop-event hook for Claude Code (and any harness with a stop/finish hook).
# It blocks the agent from ending its turn unless the MOST RECENT proof receipt
# (written by done-gate.sh) is a PASSING check that has not already been used to
# clear a previous stop. In plain terms:
#
#   "Your last recorded check must be a fresh, green one — or you can't say done."
#
# This is a FORCING FUNCTION, not a semantic oracle: it confirms a check ran and
# passed since your previous completion. It does not judge whether it was the
# RIGHT check — you choose that. (Semantic binding is on the v0.2 roadmap.)
#
# Design (why it's trustworthy):
#   * Reads the LAST line of the latest run's ledger — the most recent receipt.
#     If it failed (exit_code != 0) the gate blocks: a failing check can never
#     satisfy "done".
#   * "Consume on allow": when the gate allows a stop it records that receipt's
#     sha in .agent-proof/.gate/consumed. A subsequent stop with no NEW passing
#     receipt sees the same sha and blocks. So every completion claim must be
#     backed by its own fresh verification.
#   * Freshness guard: if the ledger is older than AGENT_DONE_TTL seconds
#     (default 3600) the gate treats it as stale and blocks — this kills the
#     "yesterday's ledger satisfies today" false-allow.
#
# Enable (Claude Code settings.json):
#   "hooks": { "Stop": [{ "hooks": [{ "type": "command",
#     "command": "bash $CLAUDE_PROJECT_DIR/stop-gate.sh" }] }] }
#
# Bypass (escape hatch): export AGENT_DONE_OFF=1
#
# Exits:  0 = allow (disabled, fresh passing+unconsumed receipt, loop retry, or
#             genuine ambiguity — FAIL OPEN so the gate never bricks the agent).
#         2 = block (no receipt / stale / last check failed / already consumed).
#
# Constraints: no network, no LLM, no jq. Portable bash + coreutils.
set -uo pipefail

# --- escape hatch -------------------------------------------------------------
[ "${AGENT_DONE_OFF:-0}" = "1" ] && exit 0

# --- read the hook payload (empty stdin => nothing to gate, allow) ------------
payload=""
if [ ! -t 0 ]; then
  payload="$(cat 2>/dev/null || true)"
fi
[ -z "$payload" ] && exit 0

# Extract a JSON boolean (true) for a key without jq.
extract_bool() {
  printf '%s' "$payload" | tr '\r\n' '  ' \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*true" | head -n1 \
    | grep -c 'true' 2>/dev/null || true
}

# --- loop guard: Claude sets stop_hook_active=true on the retry Stop event. ---
# Without this, a block here would loop forever. This guard MUST remain.
if [ "$(extract_bool stop_hook_active)" -gt 0 ] 2>/dev/null; then
  exit 0
fi

# --- locate the proof dir (fail open on any structural error) -----------------
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  root="$CLAUDE_PROJECT_DIR"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || root="$(cd "$(dirname "$0")" && pwd)"
fi
proof_dir="${AGENT_DONE_DIR:-$root/.agent-proof}"
latest_ptr="$proof_dir/latest"

block() {
  {
    printf 'stop-gate: BLOCKED — %s\n' "$1"
    printf 'stop-gate: prove your work first:\n'
    printf 'stop-gate:   bash done-gate.sh capture --label check -- <your test/build/run command>\n'
    printf 'stop-gate: then finish. (escape hatch: export AGENT_DONE_OFF=1)\n'
  } 1>&2
  exit 2
}

# No proof ever captured → block (this is a clear answer, not ambiguity).
[ -f "$latest_ptr" ] || block "no proof receipt found for this project"

run="$(cat "$latest_ptr" 2>/dev/null | tr -d '[:space:]' || true)"
[ -n "$run" ] || exit 0   # pointer unreadable/empty → ambiguous → fail open
ledger="$proof_dir/$run/ledger.jsonl"
[ -f "$ledger" ] || block "proof pointer found (run=$run) but ledger is missing"

# --- freshness guard: reject a stale ledger -----------------------------------
# mtime via GNU stat (-c) or BSD stat (-f); skip the check if neither exists.
ttl="${AGENT_DONE_TTL:-3600}"
mtime=""
if command -v stat >/dev/null 2>&1; then
  mtime="$(stat -c %Y "$ledger" 2>/dev/null || stat -f %m "$ledger" 2>/dev/null || true)"
fi
if [ -n "$mtime" ] && [ "$ttl" -gt 0 ] 2>/dev/null; then
  now="$(date +%s 2>/dev/null || true)"
  if [ -n "$now" ] && [ "$((now - mtime))" -gt "$ttl" ] 2>/dev/null; then
    block "latest proof is older than ${ttl}s (stale) — run your check again"
  fi
fi

# --- inspect the most recent receipt (last non-empty ledger line) -------------
last_line="$(grep -E '.' "$ledger" 2>/dev/null | tail -n1 || true)"
[ -n "$last_line" ] || block "proof ledger is empty — no checks were captured"

exit_code="$(printf '%s' "$last_line" | grep -oE '"exit_code":[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
sha="$(printf '%s' "$last_line" | grep -oE '"sha256":"[0-9a-f]+"' | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/' || true)"

# Can't parse the receipt → ambiguous → fail open.
[ -n "$exit_code" ] && [ -n "$sha" ] || exit 0

# Most recent check failed → block. A red check can never mean "done".
[ "$exit_code" = "0" ] || block "your most recent check FAILED (exit=$exit_code) — fix it, don't ship it"

# --- consume-on-allow: require a NEW passing receipt since the last stop -------
# Identify "newness" by run id + receipt count, NOT by the output hash: two
# passing checks with identical output (e.g. a deterministic "5 passed") would
# otherwise collide and wrongly block a legitimate re-run. A new receipt always
# advances the count (or starts a new run), so each completion needs its own.
count="$(grep -cE '.' "$ledger" 2>/dev/null || printf '0')"
token="$run:$count"

gate_dir="$proof_dir/.gate"
consumed_file="$gate_dir/consumed"
consumed=""
[ -f "$consumed_file" ] && consumed="$(cat "$consumed_file" 2>/dev/null | tr -d '[:space:]' || true)"

if [ "$token" = "$consumed" ]; then
  block "no NEW passing check since your last completion — re-verify this change"
fi

# Allow, and consume this receipt so the next "done" needs its own proof.
mkdir -p "$gate_dir" 2>/dev/null || true
printf '%s\n' "$token" > "$gate_dir/consumed.$$.tmp" 2>/dev/null \
  && mv -f "$gate_dir/consumed.$$.tmp" "$consumed_file" 2>/dev/null || true

printf 'stop-gate: OK — verified by a fresh passing receipt (sha256=%s)\n' "$sha" >&2
exit 0
