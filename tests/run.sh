#!/usr/bin/env bash
# tests/run.sh — behavior tests for done-gate.sh + stop-gate.sh.
# Dependency-free; runs each scenario in a throwaway temp dir. No network.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DONE_GATE="$REPO/done-gate.sh"
STOP_GATE="$REPO/stop-gate.sh"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Run stop-gate with a JSON payload on stdin; echo its exit code.
gate() { printf '%s' "$1" | bash "$STOP_GATE" >/dev/null 2>&1; printf '%s' "$?"; }

newsandbox() {
  local d; d="$(mktemp -d)"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  printf '%s' "$d"
}

PAYLOAD='{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}'
RETRY='{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":true}'

echo "== done-gate.sh =="

# 1. capture exits with the command's own code (pass).
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "capture returns 0 for a passing command" || bad "capture passing exit"

# 2. capture exits non-zero for a failing command (green can't be faked).
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label t -- false >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "capture propagates a failing exit code" || bad "capture failing exit"

# 3. ledger records sha256 + exit_code.
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
if grep -q '"sha256":"[0-9a-f]' "$d/.agent-proof"/*/ledger.jsonl 2>/dev/null \
   && grep -q '"exit_code":0' "$d/.agent-proof"/*/ledger.jsonl 2>/dev/null; then
  ok "ledger records sha256 and exit_code"
else bad "ledger contents"; fi

# 4. verify matches the recorded hash.
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
  sha="$(grep -oE '"sha256":"[0-9a-f]+"' .agent-proof/*/ledger.jsonl | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/')"
  bash "$DONE_GATE" verify --label t --sha "$sha" >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "verify accepts the matching hash" || bad "verify match"

echo "== stop-gate.sh =="

# 5. block when no proof exists.
d="$(newsandbox)"; rc="$( cd "$d" && gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks when no proof receipt exists" || bad "no-proof block (got $rc)"

# 6. allow after a fresh passing capture.
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1; gate "$PAYLOAD" )"
[ "$rc" = "0" ] && ok "allows after a fresh passing check" || bad "fresh-pass allow (got $rc)"

# 7. block when the most recent check failed.
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- false >/dev/null 2>&1; gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks when the latest check failed" || bad "failed-check block (got $rc)"

# 8. block on a second stop with no NEW passing check (consume-on-allow).
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
       gate "$PAYLOAD" >/dev/null; gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks a repeat stop without a new receipt" || bad "consume block (got $rc)"

# 9. allow again after a new passing capture.
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
       gate "$PAYLOAD" >/dev/null
       sleep 1; bash "$DONE_GATE" capture --label t2 -- true >/dev/null 2>&1
       gate "$PAYLOAD" )"
[ "$rc" = "0" ] && ok "allows again after a new passing check" || bad "re-verify allow (got $rc)"

# 10. loop-guard: stop_hook_active=true always allows (never loops).
d="$(newsandbox)"; rc="$( cd "$d" && gate "$RETRY" )"
[ "$rc" = "0" ] && ok "loop-guard allows on stop_hook_active" || bad "loop-guard (got $rc)"

# 11. stale ledger is rejected (freshness guard).
d="$(newsandbox)"
( cd "$d" && AGENT_DONE_TTL=1 bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
sleep 2
rc="$( cd "$d" && AGENT_DONE_TTL=1 gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks a stale (expired-TTL) ledger" || bad "stale-ledger block (got $rc)"

# 12. escape hatch always allows.
d="$(newsandbox)"
rc="$( cd "$d" && printf '%s' "$PAYLOAD" | AGENT_DONE_OFF=1 bash "$STOP_GATE" >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "0" ] && ok "escape hatch (AGENT_DONE_OFF=1) allows" || bad "escape hatch (got $rc)"

echo
printf 'Result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
