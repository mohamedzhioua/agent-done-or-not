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
  local d
  d="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp -d failed" >&2; exit 99; }
  if ! ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
           && git commit -q --allow-empty -m init ) >/dev/null 2>&1; then
    echo "FATAL: sandbox git init failed in $d" >&2; exit 99
  fi
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

# 3. ledger records sha256 + exit_code + epoch.
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
if grep -q '"sha256":"[0-9a-f]' "$d/.agent-proof"/*/ledger.jsonl 2>/dev/null \
   && grep -q '"exit_code":0' "$d/.agent-proof"/*/ledger.jsonl 2>/dev/null \
   && grep -q '"epoch":[0-9]' "$d/.agent-proof"/*/ledger.jsonl 2>/dev/null; then
  ok "ledger records sha256, exit_code and epoch"
else bad "ledger contents"; fi

# 4. verify matches the recorded hash.
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
  sha="$(grep -oE '"sha256":"[0-9a-f]+"' .agent-proof/*/ledger.jsonl | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/')"
  bash "$DONE_GATE" verify --label t --sha "$sha" >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "verify accepts the matching hash" || bad "verify match"

# 5. path-unsafe label is rejected (no traversal).
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label "../evil" -- true >/dev/null 2>&1 )
[ "$?" = "2" ] && ok "rejects a path-unsafe --label" || bad "label validation"

# 6. valueless option fails controlled (not an unbound-var crash).
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label >/dev/null 2>&1 )
[ "$?" = "2" ] && ok "valueless --label fails with exit 2" || bad "valueless option"

echo "== stop-gate.sh =="

# 7. block when no proof exists.
d="$(newsandbox)"; rc="$( cd "$d" && gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks when no proof receipt exists" || bad "no-proof block (got $rc)"

# 8. allow after a fresh passing capture.
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1; gate "$PAYLOAD" )"
[ "$rc" = "0" ] && ok "allows after a fresh passing check" || bad "fresh-pass allow (got $rc)"

# 9. block when the most recent check failed.
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- false >/dev/null 2>&1; gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks when the latest check failed" || bad "failed-check block (got $rc)"

# 10. block on a second stop with no NEW passing check (consume-on-allow).
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
       gate "$PAYLOAD" >/dev/null; gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks a repeat stop without a new receipt" || bad "consume block (got $rc)"

# 11. allow again after a new passing capture.
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
       gate "$PAYLOAD" >/dev/null
       sleep 1; bash "$DONE_GATE" capture --label t2 -- true >/dev/null 2>&1
       gate "$PAYLOAD" )"
[ "$rc" = "0" ] && ok "allows again after a new passing check" || bad "re-verify allow (got $rc)"

# 12. stop_hook_active does NOT bypass the gate (no blanket allow).
d="$(newsandbox)"; rc="$( cd "$d" && gate "$RETRY" )"
[ "$rc" = "2" ] && ok "stop_hook_active does not bypass an unproven stop" || bad "loop-guard bypass (got $rc)"

# 13. retry cap fails OPEN as an anti-infinite-loop safety valve.
d="$(newsandbox)"
rc="$( cd "$d" && AGENT_DONE_MAX_RETRIES=2 gate "$PAYLOAD" >/dev/null
       AGENT_DONE_MAX_RETRIES=2 gate "$PAYLOAD" )"
[ "$rc" = "0" ] && ok "fails open after MAX_RETRIES (no infinite loop)" || bad "retry cap (got $rc)"

# 14. stale ledger is rejected (freshness via recorded epoch).
d="$(newsandbox)"
( cd "$d" && AGENT_DONE_TTL=1 bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
sleep 2
rc="$( cd "$d" && AGENT_DONE_TTL=1 gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks a stale (expired-TTL) receipt" || bad "stale-receipt block (got $rc)"

# 15. empty latest pointer fails CLOSED.
d="$(newsandbox)"
( cd "$d" && mkdir -p .agent-proof && : > .agent-proof/latest )
rc="$( cd "$d" && gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks on an empty latest pointer (fail closed)" || bad "empty-latest (got $rc)"

# 16. unparseable receipt fails CLOSED.
d="$(newsandbox)"
( cd "$d" && mkdir -p .agent-proof/r1 && printf 'not json\n' > .agent-proof/r1/ledger.jsonl \
    && printf 'r1\n' > .agent-proof/latest )
rc="$( cd "$d" && gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks on an unparseable receipt (fail closed)" || bad "unparseable (got $rc)"

# 17. consume-persistence failure fails CLOSED (.gate cannot be created).
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
       : > .agent-proof/.gate    # a regular file blocks mkdir of the .gate dir
       gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "blocks when consume cannot be persisted" || bad "consume-persist (got $rc)"

# 18. escape hatch always allows.
d="$(newsandbox)"
rc="$( cd "$d" && printf '%s' "$PAYLOAD" | AGENT_DONE_OFF=1 bash "$STOP_GATE" >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "0" ] && ok "escape hatch (AGENT_DONE_OFF=1) allows" || bad "escape hatch (got $rc)"

echo "== assert (CI mode) =="

# 19. assert fails when there is no proof.
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" assert >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "assert fails with no proof" || bad "assert no-proof"

# 20. assert passes after a fresh passing capture (no label = latest).
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "assert passes on a fresh passing receipt" || bad "assert pass"

# 21. assert --label fails when that label failed.
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label test -- false >/dev/null 2>&1
  bash "$DONE_GATE" assert --label test >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "assert --label fails on a failing check" || bad "assert label-fail"

# 22. assert requires ALL labels (missing one fails).
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert --label test --label build >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "assert fails when a required label is missing" || bad "assert all-labels"

# 23. assert --ttl rejects a stale receipt.
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
sleep 2
( cd "$d" && bash "$DONE_GATE" assert --label t --ttl 1 >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "assert --ttl rejects a stale receipt" || bad "assert ttl"

# 24. assert --allow-command-regex enforces the command class.
d="$(newsandbox)"; ( cd "$d" && bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert --label test --allow-command-regex '^true$' >/dev/null 2>&1 )
ok_match=$?
( cd "$d" && bash "$DONE_GATE" assert --label test --allow-command-regex '^npm ' >/dev/null 2>&1 )
bad_match=$?
[ "$ok_match" = "0" ] && [ "$bad_match" = "1" ] \
  && ok "assert --allow-command-regex matches the right command class" || bad "assert regex ($ok_match/$bad_match)"

echo "== --json output =="

# 25. capture --json emits a parseable receipt.
d="$(newsandbox)"
out="$( cd "$d" && bash "$DONE_GATE" capture --json --label t -- true 2>/dev/null )"
printf '%s' "$out" | python -c "import sys,json; d=json.load(sys.stdin); assert d['label']=='t' and d['exit_code']==0 and d['sha256']" >/dev/null 2>&1 \
  && ok "capture --json emits a parseable receipt" || bad "capture --json"

# 26. assert --json emits ok=true on a passing receipt.
d="$(newsandbox)"
out="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
        bash "$DONE_GATE" assert --json --label t 2>/dev/null )"
printf '%s' "$out" | python -c "import sys,json; d=json.load(sys.stdin); assert d['ok'] is True and d['checks'][0]['label']=='t'" >/dev/null 2>&1 \
  && ok "assert --json emits ok=true" || bad "assert --json"

# 27. verify --json emits ok=true for a matching hash.
d="$(newsandbox)"
out="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
        sha="$(grep -oE '"sha256":"[0-9a-f]+"' .agent-proof/*/ledger.jsonl | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/')"
        bash "$DONE_GATE" verify --json --label t --sha "$sha" 2>/dev/null )"
printf '%s' "$out" | python -c "import sys,json; d=json.load(sys.stdin); assert d['ok'] is True" >/dev/null 2>&1 \
  && ok "verify --json emits ok=true on match" || bad "verify --json"

# 28. show --json emits a parseable receipts array.
d="$(newsandbox)"
out="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
        bash "$DONE_GATE" show --json 2>/dev/null )"
printf '%s' "$out" | python -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d['receipts'],list) and d['receipts'][0]['label']=='t'" >/dev/null 2>&1 \
  && ok "show --json emits a receipts array" || bad "show --json"

echo
printf 'Result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
