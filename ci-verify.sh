#!/usr/bin/env bash
# ci-verify.sh — the engine behind the GitHub Action's `mode: verify`.
#
# Re-runs each declared check FRESH (ignoring any committed .agent-proof/) and
# fails if any check is red. Extracted from action.yml so the verify flow is
# unit-testable rather than only grep-able.
#
# Reads from the environment (set by action.yml):
#   INPUT_CHECKS              one "label: command" per line ("#" comments / blanks ok)
#   INPUT_TTL                 optional receipt TTL; empty => 0 (just-captured = fresh)
#   INPUT_ALLOW_COMMAND_REGEX optional regex the RECORDED command must match
#   INPUT_JSON               "true" => assert emits JSON
#   INPUT_WORKING_DIRECTORY  dir to run from (default ".")
# Uses done-gate.sh next to this script (override with AGENT_DONE_GATE). Honors the
# GitHub env when present (GITHUB_STEP_SUMMARY/OUTPUT, RUNNER_TEMP, GITHUB_RUN_ID/
# ATTEMPT/REF). Exits 0 only if EVERY declared check was re-run fresh and passed.
set -uo pipefail

CI_VERIFY_VERSION="0.13.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="${AGENT_DONE_GATE:-$HERE/done-gate.sh}"

INPUT_CHECKS="${INPUT_CHECKS:-}"
INPUT_TTL="${INPUT_TTL:-}"
INPUT_ALLOW_COMMAND_REGEX="${INPUT_ALLOW_COMMAND_REGEX:-}"
INPUT_JSON="${INPUT_JSON:-false}"
INPUT_WORKING_DIRECTORY="${INPUT_WORKING_DIRECTORY:-.}"

cd "$INPUT_WORKING_DIRECTORY" || { printf 'agent-done-or-not: cannot cd to %s\n' "$INPUT_WORKING_DIRECTORY" >&2; exit 2; }

if [ -z "$(printf '%s' "$INPUT_CHECKS" | tr -d '[:space:]')" ]; then
  printf 'agent-done-or-not: mode: verify requires a non-empty "checks" input (one "label: command" per line).\n' >&2
  exit 2
fi

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
# Same rule as done-gate.sh valid_name: labels become directory/file names.
valid_label() { case "$1" in ''|*..*) return 1 ;; *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# A CI-run-scoped run id so EVERY fresh capture lands in ONE ledger that a single
# `assert --run <this> --label ...` reads — never the mutable `latest` pointer.
export AGENT_DONE_SESSION="ci-verify-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
export AGENT_DONE_VERIFIER="ci-verify.sh@$CI_VERIFY_VERSION"

# Resolve the proof dir exactly as done-gate.sh does (respecting an override).
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
proof_dir="${AGENT_DONE_DIR:-$root/.agent-proof}"
ledger="$proof_dir/$AGENT_DONE_SESSION/ledger.jsonl"

labels=()
cap_status=0

# Re-run every declared check FRESH from the pinned engine. We deliberately ignore
# any committed .agent-proof/: `capture` appends a new receipt and the assert below
# reads only this run, so a hand-written green receipt cannot survive a red re-run.
while IFS= read -r rawline; do
  line="$(trim "${rawline%$'\r'}")"
  [ -z "$line" ] && continue
  case "$line" in
    \#*) continue ;;
    *:*) ;;
    *) printf 'agent-done-or-not: bad check line (expected "label: command"): %s\n' "$line" >&2; exit 2 ;;
  esac
  label="$(trim "${line%%:*}")"
  command="$(trim "${line#*:}")"
  if [ -z "$label" ] || [ -z "$command" ]; then
    printf 'agent-done-or-not: bad check line (expected "label: command"): %s\n' "$line" >&2
    exit 2
  fi
  if ! valid_label "$label"; then
    printf 'agent-done-or-not: invalid label "%s" (allowed characters: A-Za-z0-9._-).\n' "$label" >&2
    exit 2
  fi
  printf '::group::verify %s\n' "$label"
  # stdin from /dev/null: a check that reads stdin (a REPL, `cat`, some linters)
  # must NOT be able to swallow the remaining check lines — the here-string still
  # feeding this loop — and silently drop later checks into a false green.
  bash "$GATE" capture --label "$label" -- bash -c "$command" </dev/null
  rc=$?
  printf '::endgroup::\n'
  [ "$rc" -ne 0 ] && cap_status=1
  labels+=("$label")
done <<< "$INPUT_CHECKS"

if [ "${#labels[@]}" -eq 0 ]; then
  printf 'agent-done-or-not: no runnable checks parsed from "checks" input.\n' >&2
  exit 2
fi

# Assert the FRESH receipts. Pin --run to THIS CI-scoped run (NOT the mutable
# latest pointer) so untrusted code under test cannot repoint `latest` to a
# committed forgery between capture and assert. Assert by EXPLICIT --label (not
# policy mode) so the global newest-epoch search can't pick a forged high-epoch
# receipt either. Freshness is meaningless for receipts we just made, so ttl
# defaults to 0 unless the caller set one (avoids a false red on very long suites).
args=(assert --run "$AGENT_DONE_SESSION")
for l in "${labels[@]}"; do args+=(--label "$l"); done
if [ -n "$INPUT_TTL" ]; then args+=(--ttl "$INPUT_TTL"); else args+=(--ttl 0); fi
[ -n "$INPUT_ALLOW_COMMAND_REGEX" ] && args+=(--allow-command-regex "$INPUT_ALLOW_COMMAND_REGEX")
[ "$INPUT_JSON" = "true" ] && args+=(--json)

output="$(bash "$GATE" "${args[@]}" 2>&1)"
assert_status=$?
printf '%s\n' "$output"

status=0
[ "$cap_status" -ne 0 ] && status=1
[ "$assert_status" -ne 0 ] && status=1

commit="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"

# Publish each fresh receipt's SHA-256 + the commit it was verified against.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '## agent-done-or-not: CI-verified receipts\n\n'
    printf -- '- mode: `verify`\n'
    printf -- '- commit: `%s`\n' "$commit"
    printf -- '- ref: `%s`\n' "${GITHUB_REF:-unknown}"
    printf -- '- status: `%s`\n\n' "$status"
    printf '| label | exit | sha256 |\n|---|---|---|\n'
    for l in "${labels[@]}"; do
      rline="$(grep -F "\"label\":\"$l\"" "$ledger" 2>/dev/null | tail -n1 || true)"
      rexit="$(printf '%s' "$rline" | grep -oE '"exit_code":[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
      rsha="$(printf '%s' "$rline" | grep -oE '"sha256":"[0-9a-f]+"' | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/' || true)"
      # label is valid_label-checked (no markdown metachars), but escape anyway.
      printf '| `%s` | `%s` | `%s` |\n' "$(esc "$l")" "${rexit:-?}" "${rsha:-missing}"
    done
    printf '\n<pre>\n'
    esc "$output"; printf '\n'
    printf '</pre>\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Expose the proof dir for the artifact step, and mirror the output/status into
# RUNNER_TEMP so the shared PR-comment step can post it.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'proof-dir=%s\n' "$proof_dir" >> "$GITHUB_OUTPUT"
fi
if [ -n "${RUNNER_TEMP:-}" ]; then
  printf '%s' "$output" > "$RUNNER_TEMP/agent-done-assert-output.txt"
  printf '%s' "$status" > "$RUNNER_TEMP/agent-done-assert-status.txt"
fi

exit "$status"
