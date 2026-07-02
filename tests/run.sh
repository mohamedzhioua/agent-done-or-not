#!/usr/bin/env bash
# tests/run.sh — behavior tests for done-gate.sh + stop-gate.sh.
# Dependency-free; runs each scenario in a throwaway temp dir. No network.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DONE_GATE="$REPO/done-gate.sh"
STOP_GATE="$REPO/stop-gate.sh"
INSTALLER="$REPO/install.sh"

if ! python3 -c 'pass' >/dev/null 2>&1 && python -c 'pass' >/dev/null 2>&1; then
  python3() { python "$@"; }
fi

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

echo "== install.sh =="

# 1. installer copies both scripts and makes them executable.
d="$(newsandbox)"
( cd "$d" && AGENT_DONE_LOCAL_SRC="$REPO" sh "$INSTALLER" >/dev/null 2>&1 )
[ "$?" = "0" ] && [ -x "$d/done-gate.sh" ] && [ -x "$d/stop-gate.sh" ] \
  && ok "installer copies both gate scripts as executable" || bad "installer copy/chmod"

# 2. installer adds .agent-proof/ to .gitignore once, even when re-run.
d="$(newsandbox)"
( cd "$d" && AGENT_DONE_LOCAL_SRC="$REPO" sh "$INSTALLER" >/dev/null 2>&1 \
  && AGENT_DONE_LOCAL_SRC="$REPO" sh "$INSTALLER" >/dev/null 2>&1 )
rc="$?"
count="$(grep -Fx '.agent-proof/' "$d/.gitignore" 2>/dev/null | wc -l | tr -d ' ')"
[ "$rc" = "0" ] && [ "$count" = "1" ] \
  && ok "installer adds .agent-proof/ to .gitignore idempotently" || bad "installer gitignore idempotency"

# 3. installed done-gate works end-to-end in the target repo.
d="$(newsandbox)"
( cd "$d" && AGENT_DONE_LOCAL_SRC="$REPO" sh "$INSTALLER" >/dev/null 2>&1 \
  && bash ./done-gate.sh capture --label t -- true >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "installed done-gate captures a passing check" || bad "installed done-gate smoke"

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

echo "== GitHub Action =="

# 29. action.yml declares a composite action with the expected inputs.
if [ -f "$REPO/action.yml" ] \
   && grep -q '^  using: composite$' "$REPO/action.yml" \
   && grep -q '^  mode:$' "$REPO/action.yml" \
   && grep -q '^  labels:$' "$REPO/action.yml" \
   && grep -q '^  working-directory:$' "$REPO/action.yml"; then
  ok "action.yml declares the composite action inputs"
else bad "action.yml composite/input structure"; fi

# 30. action.yml resolves its own done-gate.sh and expands labels into flags.
if grep -q 'GITHUB_ACTION_PATH/done-gate.sh' "$REPO/action.yml" \
   && grep -Fq 'read -r -a labels <<< "$INPUT_LABELS"' "$REPO/action.yml" \
   && grep -Fq 'args+=(--ttl "$INPUT_TTL")' "$REPO/action.yml" \
   && grep -Fq 'args+=(--allow-command-regex "$INPUT_ALLOW_COMMAND_REGEX")' "$REPO/action.yml"; then
  ok "action.yml builds assert arguments without empty optional flags"
else bad "action.yml argument construction"; fi

# 31. action.yml writes a GitHub job summary without changing the assert status.
if grep -Fq 'GITHUB_STEP_SUMMARY' "$REPO/action.yml" \
   && grep -Fq 'agent-done-or-not proof summary' "$REPO/action.yml" \
   && grep -Fq 'exit "$status"' "$REPO/action.yml"; then
  ok "action.yml appends a proof job summary"
else bad "action.yml job summary"; fi

# 31b. the job-summary printf lines must run cleanly under `set -e`. A format
# string starting with `-` is parsed as a printf option and aborts the step
# (regression caught only in CI before). Execute the exact summary block here.
summary_file="$(mktemp)"
status=0
(
  set -e
  INPUT_MODE=assert
  INPUT_LABELS=selftest
  output='done-gate: assert OK   label=selftest exit=0 fresh=true'
  {
    printf '## agent-done-or-not proof summary\n\n'
    printf -- '- mode: `%s`\n' "$INPUT_MODE"
    printf -- '- labels: `%s`\n' "${INPUT_LABELS:-latest}"
    printf -- '- status: `%s`\n\n' "0"
    printf '<pre>\n'
    printf '%s\n' "$output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
    printf '</pre>\n'
  } > "$summary_file"
) || status=$?
if [ "$status" = "0" ] && grep -Fq -e '- mode: `assert`' "$summary_file" \
   && ! grep -Fq "printf '-" "$REPO/action.yml"; then
  ok "action.yml job-summary printf block runs under set -e"
else bad "action.yml job-summary printf block (leading-dash printf?)"; fi
rm -f "$summary_file"

# 32. the self-test workflow dogfoods success and expected-failure paths.
if [ -f "$REPO/.github/workflows/action-selftest.yml" ] \
   && grep -q 'actions/checkout@v4' "$REPO/.github/workflows/action-selftest.yml" \
   && grep -q 'uses: ./' "$REPO/.github/workflows/action-selftest.yml" \
   && grep -q 'continue-on-error: true' "$REPO/.github/workflows/action-selftest.yml" \
   && grep -q 'steps.missing_receipt.outcome' "$REPO/.github/workflows/action-selftest.yml"; then
  ok "action self-test workflow covers success and expected failure"
else bad "action self-test workflow structure"; fi


echo "== pre-commit hook =="

# 33. .pre-commit-hooks.yaml exists and declares the expected hook fields.
if [ -f "$REPO/.pre-commit-hooks.yaml" ]    && grep -q 'id: agent-done-assert' "$REPO/.pre-commit-hooks.yaml"    && grep -q 'pass_filenames: false' "$REPO/.pre-commit-hooks.yaml"    && grep -q 'entry: hooks/pre-commit-assert.sh' "$REPO/.pre-commit-hooks.yaml"; then
  ok ".pre-commit-hooks.yaml declares agent-done-assert hook"
else bad ".pre-commit-hooks.yaml missing or malformed"; fi

# 34. hooks/pre-commit-assert.sh exists and is executable.
if [ -x "$REPO/hooks/pre-commit-assert.sh" ]; then
  ok "hooks/pre-commit-assert.sh exists and is executable"
else bad "hooks/pre-commit-assert.sh not found or not executable"; fi

# 35. E2E pass: wrapper exits 0 when a fresh receipt exists in the sandbox cwd.
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1   && bash "$REPO/hooks/pre-commit-assert.sh" --ttl 3600 >/dev/null 2>&1 )   && ok "pre-commit wrapper exits 0 with a fresh receipt"   || bad "pre-commit wrapper exit 0 path"

# 36. E2E fail: wrapper exits non-zero when no receipt exists.
d="$(newsandbox)"
( cd "$d" && bash "$REPO/hooks/pre-commit-assert.sh" >/dev/null 2>&1 )   && bad "pre-commit wrapper should exit non-zero with no receipt"   || ok "pre-commit wrapper exits non-zero with no receipt"

echo "== claude plugin =="

# 37. plugin manifest exists, is valid JSON, and declares name + version.
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d.get('name') == 'agent-done-or-not'; assert d.get('version')" "$REPO/.claude-plugin/plugin.json" >/dev/null 2>&1 \
  && ok ".claude-plugin/plugin.json declares agent-done-or-not with a version" || bad ".claude-plugin/plugin.json"

# 38. hooks config exists, is valid JSON, and wires Stop to the canonical stop-gate.
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); stop=d.get('hooks',{}).get('Stop'); assert isinstance(stop,list) and stop; cmds=[h.get('command','') for group in stop for h in group.get('hooks',[])]; assert any('\${CLAUDE_PLUGIN_ROOT}' in c and 'stop-gate.sh' in c for c in cmds)" "$REPO/hooks/hooks.json" >/dev/null 2>&1 \
  && ok "hooks/hooks.json wires Stop through \${CLAUDE_PLUGIN_ROOT}/stop-gate.sh" || bad "hooks/hooks.json"

# 39. marketplace catalog exists at .claude-plugin/, is valid JSON, and lists the plugin.
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); plugins=d.get('plugins',[]); assert any(p.get('name') == 'agent-done-or-not' for p in plugins)" "$REPO/.claude-plugin/marketplace.json" >/dev/null 2>&1 \
  && ok ".claude-plugin/marketplace.json lists agent-done-or-not" || bad "marketplace.json"

echo "== agent skill =="

SKILL="$REPO/skills/done-or-not/SKILL.md"

# 40. skill package exists at the nested skills.sh-compatible path.
if [ -f "$SKILL" ]; then
  ok "skills/done-or-not/SKILL.md exists"
else bad "skills/done-or-not/SKILL.md missing"; fi

# 41. skill frontmatter declares the required name and description.
if [ "$(sed -n '1p' "$SKILL" 2>/dev/null)" = "---" ] \
   && [ "$(sed -n '2,/^---$/p' "$SKILL" 2>/dev/null | grep -c '^---$')" = "1" ] \
   && sed -n '2,/^---$/p' "$SKILL" 2>/dev/null | grep -q '^name:[[:space:]]*done-or-not[[:space:]]*$' \
   && sed -n '2,/^---$/p' "$SKILL" 2>/dev/null | grep -Eq '^description:[[:space:]]*[^[:space:]].*'; then
  ok "skill frontmatter declares name and non-empty description"
else bad "skill frontmatter"; fi

# 42. skill body points standalone installs at the portable proof capture command.
if grep -Fq 'npx agent-done-or-not capture' "$SKILL" 2>/dev/null \
   && grep -Fq 'done-gate.sh capture' "$SKILL" 2>/dev/null; then
  ok "skill body references npx capture with local script fallback"
else bad "skill capture instruction"; fi

echo "== npm wrapper =="

PKG="$REPO/package.json"
BIN="$REPO/bin/agent-done-or-not.js"

# 42. package.json is valid JSON with the expected name, version, and bin mapping.
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d.get('name')=='agent-done-or-not'; assert d.get('version'); assert d.get('bin',{}).get('agent-done-or-not')=='bin/agent-done-or-not.js'" "$PKG" >/dev/null 2>&1 \
  && ok "package.json declares name, version, and bin mapping" || bad "package.json"

# 43. the npm bin shim exists and is executable.
if [ -x "$BIN" ]; then
  ok "bin/agent-done-or-not.js exists and is executable"
else bad "bin/agent-done-or-not.js not found or not executable"; fi

# 44-46. end-to-end through the Node shim (guarded by node availability).
if command -v node >/dev/null 2>&1; then
  # 44. capture forwards args, preserves cwd, and records a receipt.
  d="$(newsandbox)"
  ( cd "$d" && node "$BIN" capture --label t -- true >/dev/null 2>&1 )
  [ "$?" = "0" ] && [ -d "$d/.agent-proof" ] \
    && ok "npx shim: capture exits 0 and writes a receipt in cwd" || bad "npm shim capture"

  # 45. assert passes after a fresh capture through the shim.
  d="$(newsandbox)"
  ( cd "$d" && node "$BIN" capture --label t -- true >/dev/null 2>&1 \
    && node "$BIN" assert --label t >/dev/null 2>&1 )
  [ "$?" = "0" ] && ok "npx shim: assert exits 0 on a fresh receipt" || bad "npm shim assert pass"

  # 46. assert fails (non-zero) with no receipt — exit code propagates.
  d="$(newsandbox)"
  ( cd "$d" && node "$BIN" assert --label t >/dev/null 2>&1 ) \
    && bad "npm shim assert should fail with no receipt" \
    || ok "npx shim: assert exits non-zero with no receipt (exit propagates)"

  # 47. help/smoke command exits 0.
  ( cd "$REPO" && node "$BIN" --help >/dev/null 2>&1 ) \
    && ok "npm shim: --help exits 0" || bad "npm shim --help"

  # 48. init detects npm test script and writes a managed proof block.
  d="$(newsandbox)"
  printf '{"scripts":{"test":"true"}}\n' > "$d/package.json"
  ( cd "$d" && node "$BIN" init --yes >/dev/null 2>&1 )
  if grep -Fq 'npx agent-done-or-not capture --label test -- npm run test' "$d/AGENTS.md" 2>/dev/null; then
    ok "init writes npm test proof guidance"
  else bad "init npm test guidance"; fi

  # 49. init preserves existing instructions and creates a backup.
  d="$(newsandbox)"
  printf 'keep this\n' > "$d/AGENTS.md"
  ( cd "$d" && node "$BIN" init --yes --label check --command "true" >/dev/null 2>&1 )
  if grep -Fq 'keep this' "$d/AGENTS.md" 2>/dev/null \
     && ls "$d"/AGENTS.md.agent-done-or-not.bak-* >/dev/null 2>&1; then
    ok "init preserves existing AGENTS.md with backup"
  else bad "init existing instruction preservation"; fi

  # 50. init dry-run does not write.
  d="$(newsandbox)"
  ( cd "$d" && node "$BIN" init --dry-run >/dev/null 2>&1 )
  [ ! -f "$d/AGENTS.md" ] && ok "init --dry-run writes nothing" || bad "init dry-run"

  # 51. report emits a non-green missing state when no receipt exists.
  d="$(newsandbox)"
  out="$( cd "$d" && node "$BIN" report --format json 2>/dev/null )"
  printf '%s' "$out" | python -c "import sys,json; assert json.load(sys.stdin)['state']=='missing'" >/dev/null 2>&1 \
    && ok "report --format json shows missing state" || bad "report json missing"

  # 52. skill-only simulation: no local gate scripts, but the package bin captures proof.
  d="$(newsandbox)"
  ( cd "$d" && node "$BIN" capture --label t -- true >/dev/null 2>&1 )
  [ "$?" = "0" ] && [ -d "$d/.agent-proof" ] && [ ! -f "$d/done-gate.sh" ] \
    && ok "skill-only simulation captures through package bin without local scripts" \
    || bad "skill-only package-bin capture"

  # 53. report --format html renders a real HTML table and escapes receipt content.
  d="$(newsandbox)"
  ( cd "$d" && bash "$DONE_GATE" capture --label safe -- echo '<s>' >/dev/null 2>&1 )
  out="$( cd "$d" && node "$BIN" report --format html 2>/dev/null )"
  if printf '%s' "$out" | grep -Fq '<table>' && printf '%s' "$out" | grep -Fq '<td>safe</td>' \
     && printf '%s' "$out" | grep -Fq '&lt;s&gt;' && ! printf '%s' "$out" | grep -Fq '<td>echo <s>'; then
    ok "report --format html renders an escaped HTML table"
  else bad "report html table render"; fi

  # 54. init is idempotent: a second run keeps one managed block and preserves the trailing line.
  d="$(newsandbox)"
  printf 'top line\n' > "$d/AGENTS.md"
  printf '\n\nbottom line\n' >> "$d/AGENTS.md"
  ( cd "$d" && node "$BIN" init --yes --label check --command "true" >/dev/null 2>&1 )
  ( cd "$d" && node "$BIN" init --yes --label check --command "true" >/dev/null 2>&1 )
  blocks="$(grep -Fc 'agent-done-or-not:start' "$d/AGENTS.md" 2>/dev/null)"
  if [ "$blocks" = "1" ] && grep -Fq 'bottom line' "$d/AGENTS.md" 2>/dev/null \
     && ! grep -Fq 'agent-done-or-not:end -->bottom' "$d/AGENTS.md" 2>/dev/null; then
    ok "init is idempotent and preserves trailing content separation"
  else bad "init idempotency / separation"; fi
else
  ok "npx shim e2e skipped (no node on PATH)"
  ok "npx shim e2e skipped (no node on PATH)"
  ok "npx shim e2e skipped (no node on PATH)"
  ok "npm shim help skipped (no node on PATH)"
  ok "init npm test skipped (no node on PATH)"
  ok "init backup skipped (no node on PATH)"
  ok "init dry-run skipped (no node on PATH)"
  ok "report json skipped (no node on PATH)"
  ok "skill-only simulation skipped (no node on PATH)"
  ok "report html skipped (no node on PATH)"
  ok "init idempotency skipped (no node on PATH)"
fi

echo "== packaging (Homebrew + Scoop) =="

BREW="$REPO/packaging/homebrew/agent-done-or-not.rb"
SCOOP="$REPO/packaging/scoop/agent-done-or-not.json"

# 47. Homebrew formula declares the class, pinned tarball, sha256, and bash dep.
if python3 -c "import re,sys; s=open(sys.argv[1]).read(); assert re.search(r'^class AgentDoneOrNot < Formula$', s, re.M); assert re.search(r'url \"https://github\.com/mohamedzhioua/agent-done-or-not/archive/refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+\\.tar\\.gz\"', s); assert re.search(r'sha256 \"[0-9a-f]{64}\"', s); assert 'depends_on \"bash\"' in s" "$BREW" >/dev/null 2>&1; then
  ok "homebrew formula pins a tagged tarball, sha256, and bash dependency"
else bad "homebrew formula structure/pin"; fi

# 48. Homebrew formula installs the engine and provides a launcher with a test.
if grep -Fq 'libexec.install "done-gate.sh", "stop-gate.sh"' "$BREW" \
   && grep -Fq '(bin/"agent-done-or-not").write' "$BREW" \
   && grep -q '^  test do$' "$BREW"; then
  ok "homebrew formula installs the engine, a launcher, and a test block"
else bad "homebrew formula install/test block"; fi

# 49. Scoop manifest is valid JSON and agrees with the Homebrew pinned tarball.
python3 -c "import json,re,sys; brew=open(sys.argv[1]).read(); scoop=json.load(open(sys.argv[2])); b_url=re.search(r'url \"([^\"]+)\"', brew).group(1); b_hash=re.search(r'sha256 \"([0-9a-f]{64})\"', brew).group(1); v=scoop['version']; assert scoop['url']==b_url; assert scoop['url'].endswith('/v%s.tar.gz' % v); assert scoop['hash']==b_hash; assert scoop['extract_dir']=='agent-done-or-not-%s' % v; assert scoop['bin']=='agent-done-or-not.cmd'" "$BREW" "$SCOOP" >/dev/null 2>&1 \
  && ok "scoop manifest pins the same tagged tarball/hash and shims a launcher" || bad "scoop manifest structure/pin"

# 50. Scoop launcher forwards to the bundled native PowerShell engine.
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); pi='\n'.join(d['pre_install']); assert 'done-gate.ps1' in pi and 'powershell -NoProfile' in pi and '%~dp0' in pi and 'agent-done-or-not.cmd' in pi" "$SCOOP" >/dev/null 2>&1; then
  ok "scoop pre_install writes a .cmd launcher that calls the bundled PowerShell engine"
else bad "scoop pre_install launcher"; fi

echo "== PowerShell port =="

PS_GATE="$REPO/done-gate.ps1"
PS_TESTS="$REPO/tests/run.ps1"

# 51. the PowerShell engine and its parity tests exist.
if [ -f "$PS_GATE" ] && [ -f "$PS_TESTS" ]; then
  ok "done-gate.ps1 and tests/run.ps1 exist"
else bad "PowerShell port files missing"; fi

# 52. the PowerShell parity suite passes (guarded by a PowerShell host on PATH).
PWSH=""
for c in pwsh powershell pwsh.exe powershell.exe; do
  command -v "$c" >/dev/null 2>&1 && { PWSH="$c"; break; }
done
if [ -n "$PWSH" ]; then
  if "$PWSH" -NoProfile -File "$PS_TESTS" >/dev/null 2>&1; then
    ok "PowerShell parity suite passes ($PWSH tests/run.ps1)"
  else bad "PowerShell parity suite ($PWSH tests/run.ps1)"; fi
else
  ok "PowerShell parity suite skipped (no PowerShell host on PATH)"
fi

echo "== policy + labels =="

# P1. policy: all required labels passing across SEPARATE runs -> assert passes.
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "test" }, { "label": "build" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  sleep 1
  bash "$DONE_GATE" capture --label build -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "policy: all required labels (cross-run) pass" || bad "policy cross-run pass"

# P2. policy: a required label missing -> assert fails.
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "test" }, { "label": "build" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "policy: missing required label fails" || bad "policy missing label"

# P3. policy: per-label command_regex enforced (match passes, mismatch fails).
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "test", "command_regex": "^true$" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert >/dev/null 2>&1 )
ok_match=$?
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "test", "command_regex": "npm test" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert >/dev/null 2>&1 )
bad_match=$?
[ "$ok_match" = "0" ] && [ "$bad_match" = "1" ] \
  && ok "policy: per-label command_regex enforced" || bad "policy per-label regex ($ok_match/$bad_match)"

# P4. policy: ttl from the policy file is honored (stale receipt fails).
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "test" } ], "ttl": 1 }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1 )
sleep 2
( cd "$d" && bash "$DONE_GATE" assert >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "policy: ttl from policy file rejects a stale receipt" || bad "policy ttl"

# P5. --no-policy falls back to legacy latest behavior even with a policy present.
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "build" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert --no-policy >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "--no-policy uses legacy latest receipt" || bad "--no-policy fallback"

# P6. explicit --label still overrides the policy (legacy path intact).
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "build" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert --label test >/dev/null 2>&1 )
[ "$?" = "0" ] && ok "explicit --label overrides policy" || bad "explicit label override"

# P7. assert --json carries the policy key (set in policy mode, empty in legacy).
d="$(newsandbox)"
out_pol="$( cd "$d" && printf '{ "required": [ { "label": "test" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert --json 2>/dev/null )"
out_leg="$( cd "$d" && bash "$DONE_GATE" assert --json --label test 2>/dev/null )"
if printf '%s' "$out_pol" | python -c "import sys,json; d=json.load(sys.stdin); assert d['policy']=='agent-done.json' and d['ok'] is True" >/dev/null 2>&1 \
   && printf '%s' "$out_leg" | python -c "import sys,json; d=json.load(sys.stdin); assert d['policy']=='' " >/dev/null 2>&1; then
  ok "assert --json includes the policy key"
else bad "assert --json policy key"; fi

# P8. weak-only (lint) check warns but still exits 0 (advisory, never blocks).
d="$(newsandbox)"
err="$( cd "$d" && bash "$DONE_GATE" capture --label lint -- true >/dev/null 2>&1
        bash "$DONE_GATE" assert --label lint 2>&1 >/dev/null )"
rc_warn="$( cd "$d" && bash "$DONE_GATE" assert --label lint >/dev/null 2>&1; printf '%s' "$?" )"
if [ "$rc_warn" = "0" ] && printf '%s' "$err" | grep -Fq 'WARNING — latest proof is lint-only'; then
  ok "weak-only check warns but exits 0"
else bad "weak-only warning (rc=$rc_warn)"; fi

# P9. SECURITY: a policy present but unparseable (nested brace -> 0 entries) must
# FAIL CLOSED, never silently fall back to legacy "latest receipt" and pass on a
# different label's green check.
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "build", "opts": { "x": "y" } } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "policy: unparseable required entry fails closed (no silent legacy PASS)" || bad "policy fail-closed on unparseable"

# P10. an invalid per-label command_regex fails closed (never errors into a PASS).
d="$(newsandbox)"
( cd "$d" && printf '{ "required": [ { "label": "test", "command_regex": "[" } ] }\n' > agent-done.json
  bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert >/dev/null 2>&1 )
[ "$?" = "1" ] && ok "policy: invalid command_regex fails closed" || bad "policy invalid regex"

# P11. a non-integer --ttl is rejected with exit 2 (parity with the PS engine).
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  bash "$DONE_GATE" assert --label test --ttl abc >/dev/null 2>&1 )
[ "$?" = "2" ] && ok "assert --ttl non-integer fails with exit 2" || bad "ttl integer validation"

# P12. SECURITY: an agent-controlled command containing the proof marker must not
# inject extra markers into `report --format pr` (would hijack the sticky comment).
if command -v node >/dev/null 2>&1; then
  d="$(newsandbox)"
  ( cd "$d" && bash "$DONE_GATE" capture --label test -- printf '<!-- agent-done-or-not:proof -->' >/dev/null 2>&1 )
  n="$( cd "$d" && node "$BIN" report --format pr 2>/dev/null | grep -c -- '<!-- agent-done-or-not:proof -->' )"
  [ "$n" = "2" ] && ok "report --format pr neutralizes an injected proof marker" || bad "pr marker injection (got $n markers)"
else
  ok "pr marker-injection test skipped (no node on PATH)"
fi

echo "== state binding + stop-gate policy (v0.9) =="

# S1. capture binds the receipt to git commit + tree + dirty.
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
line="$(tail -n1 "$d"/.agent-proof/*/ledger.jsonl 2>/dev/null)"
if printf '%s' "$line" | grep -qE '"commit":"[0-9a-f]{40}"' \
   && printf '%s' "$line" | grep -qE '"tree":"[0-9a-f]+"' \
   && printf '%s' "$line" | grep -qE '"dirty":(true|false)'; then
  ok "capture binds the receipt to commit + tree + dirty"
else bad "state binding: receipt is missing commit/tree/dirty"; fi

# S2. assert warns on state drift (HEAD advanced since capture) but still exits 0.
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  git commit -q --allow-empty -m next >/dev/null 2>&1 )
err="$( cd "$d" && bash "$DONE_GATE" assert --label test 2>&1 >/dev/null )"
rc="$( cd "$d" && bash "$DONE_GATE" assert --label test >/dev/null 2>&1; printf '%s' "$?" )"
if [ "$rc" = "0" ] && printf '%s' "$err" | grep -q 'HEAD is now'; then
  ok "assert warns on state drift (advisory) but exits 0"
else bad "assert drift advisory (rc=$rc)"; fi

# S3. AGENT_DONE_BIND_STATE=1 turns state drift into a hard assert failure.
d="$(newsandbox)"
( cd "$d" && bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
  git commit -q --allow-empty -m next >/dev/null 2>&1 )
rc="$( cd "$d" && AGENT_DONE_BIND_STATE=1 bash "$DONE_GATE" assert --label test >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "1" ] && ok "AGENT_DONE_BIND_STATE=1 fails assert on drift" || bad "bind-state assert (got $rc)"

# S4. stop-gate is policy-aware: a passing receipt for a NON-required label must
# not clear the gate when a policy demands other labels (the core v0.9 fix).
d="$(newsandbox)"
rc="$( cd "$d" && printf '{ "required": [ { "label": "test" }, { "label": "build" } ] }\n' > agent-done.json
       bash "$DONE_GATE" capture --label lint -- true >/dev/null 2>&1
       gate "$PAYLOAD" )"
[ "$rc" = "2" ] && ok "stop-gate blocks when a policy label lacks a passing receipt" || bad "stop-gate policy block (got $rc)"

# S5. stop-gate allows once every required policy label has a fresh passing receipt.
d="$(newsandbox)"
rc="$( cd "$d" && printf '{ "required": [ { "label": "test" }, { "label": "build" } ] }\n' > agent-done.json
       bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
       bash "$DONE_GATE" capture --label build -- true >/dev/null 2>&1
       gate "$PAYLOAD" )"
[ "$rc" = "0" ] && ok "stop-gate allows when all policy labels are satisfied" || bad "stop-gate policy allow (got $rc)"

# S6. stop-gate FAILS CLOSED when a policy is present but done-gate.sh is not next
# to it (cannot evaluate the policy -> must not silently allow).
d="$(newsandbox)"
cp "$STOP_GATE" "$d/stop-gate.sh"
rc="$( cd "$d" && printf '{ "required": [ { "label": "test" } ] }\n' > agent-done.json
       bash "$DONE_GATE" capture --label test -- true >/dev/null 2>&1
       printf '%s' "$PAYLOAD" | bash ./stop-gate.sh >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "2" ] && ok "stop-gate fails closed when it cannot evaluate a present policy" || bad "stop-gate policy fail-closed (got $rc)"

# S7. stop-gate drift is advisory by default (non-breaking).
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
       git commit -q --allow-empty -m next >/dev/null 2>&1
       gate "$PAYLOAD" )"
[ "$rc" = "0" ] && ok "stop-gate drift is advisory by default (still allows)" || bad "stop-gate drift default (got $rc)"

# S8. stop-gate blocks on drift under AGENT_DONE_BIND_STATE=1.
d="$(newsandbox)"
rc="$( cd "$d" && bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1
       git commit -q --allow-empty -m next >/dev/null 2>&1
       printf '%s' "$PAYLOAD" | AGENT_DONE_BIND_STATE=1 bash "$STOP_GATE" >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "2" ] && ok "stop-gate blocks on drift when AGENT_DONE_BIND_STATE=1" || bad "stop-gate bind-state (got $rc)"

echo "== receipt provenance (v0.10) =="

# PV1. a LOCAL capture stamps schema_version:1, ci:false and an empty ref.
# Clear CI env so this passes identically whether run locally or inside CI.
d="$(newsandbox)"
( cd "$d" && env -u CI -u GITHUB_ACTIONS -u GITHUB_REF bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
line="$(tail -n1 "$d"/.agent-proof/*/ledger.jsonl 2>/dev/null)"
if printf '%s' "$line" | grep -q '"schema_version":1' \
   && printf '%s' "$line" | grep -q '"ci":false' \
   && printf '%s' "$line" | grep -q '"ref":""'; then
  ok "local capture stamps schema_version:1, ci:false, empty ref"
else bad "provenance: local receipt (got: $line)"; fi

# PV2. a CI capture (GITHUB_ACTIONS + GITHUB_REF set) stamps ci:true and the ref.
d="$(newsandbox)"
( cd "$d" && GITHUB_ACTIONS=true GITHUB_REF=refs/pull/7/merge bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
line="$(tail -n1 "$d"/.agent-proof/*/ledger.jsonl 2>/dev/null)"
if printf '%s' "$line" | grep -q '"ci":true' \
   && printf '%s' "$line" | grep -q '"ref":"refs/pull/7/merge"'; then
  ok "CI capture stamps ci:true and the ref under test"
else bad "provenance: CI receipt (got: $line)"; fi

# PV3. CI detection also fires on a bare CI=1 (not just GITHUB_ACTIONS).
d="$(newsandbox)"
( cd "$d" && env -u GITHUB_ACTIONS CI=1 bash "$DONE_GATE" capture --label t -- true >/dev/null 2>&1 )
line="$(tail -n1 "$d"/.agent-proof/*/ledger.jsonl 2>/dev/null)"
printf '%s' "$line" | grep -q '"ci":true' \
  && ok "CI=1 alone marks the receipt ci:true" || bad "provenance: CI=1 detection (got: $line)"

# PV4. the proof schema documents the new provenance fields.
if grep -q '"schema_version"' "$REPO/proof.schema.json" \
   && grep -q '"ci"' "$REPO/proof.schema.json" \
   && grep -q '"ref"' "$REPO/proof.schema.json"; then
  ok "proof.schema.json documents schema_version, ci and ref"
else bad "proof.schema.json missing provenance fields"; fi

echo "== action verify mode (v0.10) =="

# AV1. action.yml declares mode: verify plumbing (checks input + gated step).
if grep -Eq "if: \\\$\{\{ inputs.mode == 'verify' \}\}" "$REPO/action.yml" \
   && grep -q '^  checks:$' "$REPO/action.yml" \
   && grep -q 'INPUT_CHECKS' "$REPO/action.yml"; then
  ok "action.yml declares verify mode with a checks input"
else bad "action.yml verify mode plumbing"; fi

# AV2. the verify step delegates to the testable ci-verify.sh engine.
if grep -Fq 'bash "$GITHUB_ACTION_PATH/ci-verify.sh"' "$REPO/action.yml" \
   && [ -f "$REPO/ci-verify.sh" ]; then
  ok "action.yml verify step delegates to ci-verify.sh"
else bad "action.yml verify delegates to ci-verify.sh"; fi

# AV2b. ci-verify.sh re-runs each check FRESH via capture (bash -c, stdin closed).
if grep -Fq 'bash "$GATE" capture --label "$label" -- bash -c "$command" </dev/null' "$REPO/ci-verify.sh" \
   && grep -Fq 'AGENT_DONE_SESSION="ci-verify-' "$REPO/ci-verify.sh"; then
  ok "ci-verify.sh re-runs checks fresh with stdin closed"
else bad "ci-verify.sh fresh-capture wiring"; fi

# AV2c. ci-verify.sh asserts the PINNED run (not the mutable latest pointer) and
# defaults ttl to 0 (a just-captured receipt is definitionally fresh).
if grep -Fq 'assert --run "$AGENT_DONE_SESSION"' "$REPO/ci-verify.sh" \
   && grep -Fq 'args+=(--ttl 0)' "$REPO/ci-verify.sh"; then
  ok "ci-verify.sh asserts the pinned CI run with ttl 0"
else bad "ci-verify.sh pinned-run/ttl wiring"; fi

# AV3. verify publishes the receipt artifact (action) + SHA in the summary (engine).
if grep -Fq 'uses: actions/upload-artifact@v4' "$REPO/action.yml" \
   && grep -Fq 'CI-verified receipts' "$REPO/ci-verify.sh" \
   && grep -Fq 'sha256' "$REPO/ci-verify.sh"; then
  ok "verify uploads receipts + prints SHA in the summary"
else bad "verify artifact/summary"; fi

# AV4. an unsupported mode is rejected (fail closed).
if grep -Eq "if: \\\$\{\{ inputs.mode != 'assert' && inputs.mode != 'verify' \}\}" "$REPO/action.yml"; then
  ok "action.yml rejects an unsupported mode"
else bad "action.yml mode guard"; fi

# AV5. the self-test workflow dogfoods verify success + a really-red catch.
if grep -q 'verify-success:' "$REPO/.github/workflows/action-selftest.yml" \
   && grep -q 'verify-catches-red:' "$REPO/.github/workflows/action-selftest.yml" \
   && grep -q 'steps.red_check.outcome' "$REPO/.github/workflows/action-selftest.yml"; then
  ok "action self-test covers verify success and a really-red catch"
else bad "action self-test verify jobs"; fi

# AV6. a GitHub verify template exists for making proof-of-done a required check.
if [ -f "$REPO/docs/ci-templates/github-verify.yml" ] \
   && grep -q 'mode: verify' "$REPO/docs/ci-templates/github-verify.yml" \
   && grep -q 'name: proof-of-done' "$REPO/docs/ci-templates/github-verify.yml"; then
  ok "docs/ci-templates/github-verify.yml provides a required-check template"
else bad "github-verify.yml template missing/malformed"; fi

CI_VERIFY="$REPO/ci-verify.sh"

# AV7. FUNCTIONAL (through the real ci-verify.sh): a committed GREEN receipt — even
# one with a forged huge epoch + matching commit, as the `latest` pointer — is
# IGNORED. A fresh RED re-run fails the gate. This is the core v0.10 guarantee.
d="$(newsandbox)"
rc="$( cd "$d" \
  && mkdir -p .agent-proof/committed \
  && printf '{"label":"test","command":"npm test","exit_code":0,"sha256":"deadbeef","log":"x","at":"2099-01-01T00:00:00Z","epoch":9999999999,"session":"","commit":"'"$(git rev-parse HEAD)"'","tree":"","dirty":false,"schema_version":1,"ci":true,"ref":""}\n' > .agent-proof/committed/ledger.jsonl \
  && printf 'committed\n' > .agent-proof/latest \
  && INPUT_CHECKS='test: exit 3' AGENT_DONE_GATE="$DONE_GATE" bash "$CI_VERIFY" >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "1" ] && ok "ci-verify: fresh red re-run overrides a committed (forged) green receipt" || bad "ci-verify committed-green-really-red (got $rc)"

# AV8. FUNCTIONAL: a genuinely fresh green re-run passes the gate (multi-check).
d="$(newsandbox)"
rc="$( cd "$d" && INPUT_CHECKS=$'test: true\nbuild: echo ok' AGENT_DONE_GATE="$DONE_GATE" bash "$CI_VERIFY" >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "0" ] && ok "ci-verify: fresh green re-run passes the gate" || bad "ci-verify fresh-green (got $rc)"

# AV9. REGRESSION (stdin drop): a check that reads stdin must NOT swallow the
# remaining check lines. Here `reader: cat` would eat `mustfail: false` without
# the </dev/null guard; the guard means mustfail still runs and fails the gate.
d="$(newsandbox)"
out="$( cd "$d" && INPUT_CHECKS=$'reader: cat\nmustfail: false' AGENT_DONE_GATE="$DONE_GATE" bash "$CI_VERIFY" >/dev/null 2>&1; echo "rc=$?"
        ledger="$(cat .agent-proof/*/ledger.jsonl 2>/dev/null)"
        printf '%s' "$ledger" | grep -q '"label":"reader"' && echo has_reader
        printf '%s' "$ledger" | grep -q '"label":"mustfail"' && echo has_mustfail )"
if printf '%s' "$out" | grep -q 'rc=1' \
   && printf '%s' "$out" | grep -q 'has_reader' \
   && printf '%s' "$out" | grep -q 'has_mustfail'; then
  ok "ci-verify: a stdin-reading check does not drop later checks"
else bad "ci-verify stdin-drop regression ($out)"; fi

# AV10. an invalid label is rejected before it can reach the summary (exit 2).
d="$(newsandbox)"
rc="$( cd "$d" && INPUT_CHECKS='bad/label: true' AGENT_DONE_GATE="$DONE_GATE" bash "$CI_VERIFY" >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc" = "2" ] && ok "ci-verify: rejects an invalid label with exit 2" || bad "ci-verify label validation (got $rc)"

# AV11. empty checks + comment/blank-only checks both fail fast (nothing to run).
d="$(newsandbox)"
rc1="$( cd "$d" && INPUT_CHECKS='' AGENT_DONE_GATE="$DONE_GATE" bash "$CI_VERIFY" >/dev/null 2>&1; printf '%s' "$?" )"
rc2="$( cd "$d" && INPUT_CHECKS=$'# just a comment\n\n' AGENT_DONE_GATE="$DONE_GATE" bash "$CI_VERIFY" >/dev/null 2>&1; printf '%s' "$?" )"
[ "$rc1" = "2" ] && [ "$rc2" = "2" ] && ok "ci-verify: empty / comment-only checks fail with exit 2" || bad "ci-verify empty-checks (rc1=$rc1 rc2=$rc2)"

# AV12. comments and blank lines are skipped; only real checks run.
d="$(newsandbox)"
out="$( cd "$d" && INPUT_CHECKS=$'# a comment\n\ntest: true' AGENT_DONE_GATE="$DONE_GATE" bash "$CI_VERIFY" >/dev/null 2>&1; echo "rc=$?"
        cat .agent-proof/*/ledger.jsonl 2>/dev/null | grep -c '"label":"test"' )"
if printf '%s' "$out" | grep -q 'rc=0' && printf '%s' "$out" | tail -n1 | grep -q '^1$'; then
  ok "ci-verify: comment/blank lines are skipped"
else bad "ci-verify comment skipping ($out)"; fi

echo
printf 'Result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
