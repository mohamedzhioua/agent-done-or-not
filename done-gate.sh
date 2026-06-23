#!/usr/bin/env bash
# done-gate.sh — proof receipts for AI coding agents.
#
# Your agent says "done." This makes it prove it. `capture` runs your real
# check, hashes the output, and records the command + exit code + SHA-256 in a
# tamper-evident ledger. Because capture EXITS WITH THE COMMAND'S OWN CODE, a
# failing check fails the receipt — green cannot be faked.
#
# Pairs with stop-gate.sh (the Stop hook). `assert` is the same idea for CI,
# pre-commit, and release scripts. Works with Claude Code, Cursor, and Codex.
#
# Subcommands:
#   capture --label L [--run R] [--json] -- CMD [ARGS...]
#       Run CMD, stream its output to the console AND a log file, then append a
#       JSONL receipt (label, command, exit_code, sha256, log, at, epoch,
#       session). Updates the latest-run pointer. Exits with CMD's own code.
#
#   assert [--label L ...] [--run R] [--ttl S] [--allow-command-regex RE]
#          [--policy FILE] [--no-policy] [--json]
#       Exit 0 iff every required label has a PASSING, FRESH receipt (and, if a
#       regex is given, the recorded command matches it). Resolution order:
#       explicit --label (legacy) > an agent-done.json policy (required labels +
#       per-label command_regex + ttl) > the most recent receipt. --no-policy
#       forces the legacy path. For CI / pre-commit gating.
#
#   verify --label L [--run R] [--json] --sha HEX
#       Exit 0 iff the ledger's recorded sha256 for L equals HEX.
#
#   show [--run R] [--json]
#       Print the ledger for the run (newest run if --run is omitted).
#
# Receipts live under .agent-proof/<run>/ (add .agent-proof/ to .gitignore).
# The run id defaults to $AGENT_DONE_SESSION, else a UTC timestamp.
#
# Dependency-free: SHA via sha256sum | shasum -a 256 | python hashlib; the
# ledger is hand-written JSONL. No network, no LLM, no extra tooling.
set -euo pipefail

normalize_path() {
  case "$1" in
    [A-Za-z]:/*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
      else
        printf '%s' "$1"
      fi
      ;;
    *) printf '%s' "$1" ;;
  esac
}

ROOT="$(normalize_path "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
PROOF_DIR="${AGENT_DONE_DIR:-$ROOT/.agent-proof}"

die() { printf 'done-gate: %s\n' "$1" >&2; exit 2; }

# Reject path-unsafe run ids / labels: they become directory and file names.
valid_name() {
  case "$1" in
    ''|*..*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }
epoch()     { date +%s 2>/dev/null || printf '0'; }
run_stamp() { date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf 'run'; }

sha256_of_file() {
  local f="$1" c py=""
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    for c in python3 python py; do
      command -v "$c" >/dev/null 2>&1 && { py="$c"; break; }
    done
    [ -n "$py" ] || die "no sha256 tool found (need sha256sum, shasum, or python)"
    "$py" - "$f" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as fh:
    print(hashlib.sha256(fh.read()).hexdigest())
PY
  fi
}

# Minimal JSON string escaper for label/command/path fields.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

resolve_run_for_read() {
  local r="${1:-}"
  if [ -z "$r" ]; then
    [ -f "$PROOF_DIR/latest" ] && r="$(cat "$PROOF_DIR/latest")"
  fi
  printf '%s' "$r"
}

# --- ledger field extractors (operate on a single JSONL receipt line) ---------
rec_exit()    { printf '%s' "$1" | grep -oE '"exit_code":[0-9]+' | head -n1 | grep -oE '[0-9]+'; }
rec_epoch()   { printf '%s' "$1" | grep -oE '"epoch":[0-9]+' | head -n1 | grep -oE '[0-9]+'; }
rec_sha()     { printf '%s' "$1" | grep -oE '"sha256":"[0-9a-f]+"' | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/'; }
rec_command() { printf '%s' "$1" | sed -E 's/.*"command":"(.*)","exit_code":.*/\1/'; }

# Latest receipt line for a label (fixed-string match), or empty.
latest_for_label() {
  local ledger="$1" label="$2"
  grep -F "\"label\":\"$(json_escape "$label")\"" "$ledger" 2>/dev/null | tail -n1
}

# --- policy file (agent-done.json) --------------------------------------------
# Maintainer-authored config that says what "done" requires. Trusted at the same
# level as any workspace file. Parsed dependency-free (no jq): each entry in the
# "required" array is a FLAT object, so a brace-pair match isolates them safely.
resolve_policy_path() {
  local explicit="$1"
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  if [ -n "${AGENT_DONE_POLICY:-}" ]; then printf '%s' "$AGENT_DONE_POLICY"; return 0; fi
  [ -f "$ROOT/agent-done.json" ] && printf '%s' "$ROOT/agent-done.json"
  return 0
}

# Emit one "label<TAB>command_regex" line per required entry (regex may be empty).
policy_entries() {
  local file="$1" obj label regex
  [ -f "$file" ] || return 0
  tr '\n\r' '  ' < "$file" 2>/dev/null | grep -oE '\{[^{}]*\}' | while IFS= read -r obj; do
    label="$(printf '%s' "$obj" | grep -oE '"label"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"label"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
    [ -n "$label" ] || continue
    regex="$(printf '%s' "$obj" | grep -oE '"command_regex"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"command_regex"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
    printf '%s\t%s\n' "$label" "$regex"
  done
  return 0
}

# Top-level "ttl" integer, or empty.
policy_ttl() {
  local file="$1"
  [ -f "$file" ] || return 0
  tr '\n\r' '  ' < "$file" 2>/dev/null | grep -oE '"ttl"[[:space:]]*:[[:space:]]*[0-9]+' | head -n1 | grep -oE '[0-9]+' || true
}

# Label strength taxonomy for the advisory wrong-check warning. WEAK labels are
# necessary but not sufficient on their own; unknown labels are treated STRONG so
# custom verifying commands are never nagged.
label_is_weak() {
  case "$1" in
    lint|format|fmt|style|manual|docs) return 0 ;;
    *) return 1 ;;
  esac
}

# Most recent receipt for a label across ALL runs (highest recorded epoch), or
# empty. Policy mode uses this so receipts captured in separate run dirs (the
# default when no AGENT_DONE_SESSION is set) still satisfy required labels.
latest_for_label_global() {
  local label="$1" pat f line ep best="" best_ep=-1
  pat="\"label\":\"$(json_escape "$label")\""
  for f in "$PROOF_DIR"/*/ledger.jsonl; do
    [ -f "$f" ] || continue
    line="$(grep -F "$pat" "$f" 2>/dev/null | tail -n1 || true)"
    [ -n "$line" ] || continue
    ep="$(printf '%s' "$line" | grep -oE '"epoch":[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
    [ -n "$ep" ] || ep=0
    if [ "$ep" -gt "$best_ep" ] 2>/dev/null; then best_ep="$ep"; best="$line"; fi
  done
  printf '%s' "$best"
}

cmd_capture() {
  local label="" run="" json=0 ; local -a CMD=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) [ "$#" -ge 2 ] || die "capture: --label requires a value"; label="$2"; shift 2 ;;
      --run)   [ "$#" -ge 2 ] || die "capture: --run requires a value";   run="$2";   shift 2 ;;
      --json)  json=1; shift ;;
      --)      shift; CMD=("$@"); break ;;
      *)       die "capture: unexpected arg '$1' (did you forget '--' before the command?)" ;;
    esac
  done
  [ -n "$label" ] || die "capture: --label is required"
  [ "${#CMD[@]}" -ge 1 ] || die "capture: a command after '--' is required"
  valid_name "$label" || die "capture: --label must match [A-Za-z0-9._-] and contain no '..'"

  run="${run:-${AGENT_DONE_SESSION:-$(run_stamp)}}"
  valid_name "$run" || die "capture: run id must match [A-Za-z0-9._-] and contain no '..'"
  local dir="$PROOF_DIR/$run"
  mkdir -p "$dir"
  local log="$dir/$label.log"

  local rc
  set +e
  ( "${CMD[@]}" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  local sha; sha="$(sha256_of_file "$log")"
  local receipt
  receipt="$(printf '{"label":"%s","command":"%s","exit_code":%s,"sha256":"%s","log":"%s","at":"%s","epoch":%s,"session":"%s"}' \
    "$(json_escape "$label")" "$(json_escape "${CMD[*]}")" "$rc" "$sha" \
    "$(json_escape "${log#"$ROOT/"}")" "$(timestamp)" "$(epoch)" \
    "$(json_escape "${AGENT_DONE_SESSION:-}")")"
  printf '%s\n' "$receipt" >> "$dir/ledger.jsonl"

  printf '%s\n' "$run" > "$PROOF_DIR/latest.$$.tmp" && mv -f "$PROOF_DIR/latest.$$.tmp" "$PROOF_DIR/latest"

  if [ "$json" = "1" ]; then
    printf '%s\n' "$receipt"
  fi
  printf 'done-gate: captured label=%s run=%s exit=%s sha256=%s\n' "$label" "$run" "$rc" "$sha" >&2
  return "$rc"
}

cmd_assert() {
  local run="" ttl="" regex="" json=0 policy_flag="" no_policy=0
  local -a LABELS=() LABEL_REGEXES=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) [ "$#" -ge 2 ] || die "assert: --label requires a value"; LABELS+=("$2"); shift 2 ;;
      --run)   [ "$#" -ge 2 ] || die "assert: --run requires a value";   run="$2";   shift 2 ;;
      --ttl)   [ "$#" -ge 2 ] || die "assert: --ttl requires a value";   ttl="$2";   shift 2 ;;
      --allow-command-regex) [ "$#" -ge 2 ] || die "assert: --allow-command-regex requires a value"; regex="$2"; shift 2 ;;
      --policy) [ "$#" -ge 2 ] || die "assert: --policy requires a value"; policy_flag="$2"; shift 2 ;;
      --no-policy) no_policy=1; shift ;;
      --json)  json=1; shift ;;
      *)       die "assert: unexpected arg '$1'" ;;
    esac
  done
  regex="${regex:-${AGENT_DONE_ALLOWED_COMMANDS:-}}"

  # Resolution order: explicit CLI --label (legacy) > policy file > latest receipt.
  # CLI labels override everything so existing call sites are unchanged.
  local policy_used="" policy_mode=0
  if [ "${#LABELS[@]}" -gt 0 ]; then
    local _l
    for _l in "${LABELS[@]}"; do LABEL_REGEXES+=("$regex"); done
  elif [ "$no_policy" != "1" ]; then
    local policy_path; policy_path="$(resolve_policy_path "$policy_flag")"
    if [ -n "$policy_path" ] && [ -f "$policy_path" ]; then
      policy_used="${policy_path#"$ROOT/"}"
      local _lbl _rx _pttl
      while IFS="$(printf '\t')" read -r _lbl _rx; do
        [ -n "$_lbl" ] || continue
        LABELS+=("$_lbl")
        if [ -n "$_rx" ]; then LABEL_REGEXES+=("$_rx"); else LABEL_REGEXES+=("$regex"); fi
      done <<EOF
$(policy_entries "$policy_path")
EOF
      # A policy file was explicitly present but yielded no parseable "required"
      # entries — FAIL CLOSED instead of silently degrading to the latest-receipt
      # path (a policy that says "do more" must never quietly do less).
      if [ "${#LABELS[@]}" -eq 0 ]; then
        [ "$json" = "1" ] && printf '{"ok":false,"reason":"policy present but no parseable required entries","policy":"%s","checks":[]}\n' "$(json_escape "$policy_used")"
        printf 'done-gate: assert FAIL — policy %s present but no parseable "required" entries (check for nested braces / quoting)\n' "$policy_used" >&2
        return 1
      fi
      policy_mode=1
      if [ -z "$ttl" ]; then _pttl="$(policy_ttl "$policy_path")"; [ -n "$_pttl" ] && ttl="$_pttl"; fi
    fi
  fi
  ttl="${ttl:-${AGENT_DONE_TTL:-3600}}"
  case "$ttl" in ''|*[!0-9]*) die "assert: --ttl must be a non-negative integer" ;; esac

  # Run-scoped modes need a resolved run + ledger. Policy mode searches all runs
  # per label, so it only needs the proof dir to contain at least one ledger.
  local ledger="" run_label="$run"
  if [ "$policy_mode" = "1" ]; then
    run_label="*"
    if [ -z "$(ls -1 "$PROOF_DIR"/*/ledger.jsonl 2>/dev/null || true)" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"reason":"no proof receipts found","policy":"%s","checks":[]}\n' "$(json_escape "$policy_used")"
      printf 'done-gate: assert FAIL — no proof receipts found (capture something first)\n' >&2
      return 1
    fi
  else
    run="$(resolve_run_for_read "$run")"
    if [ -z "$run" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"reason":"no proof run found","policy":"%s","checks":[]}\n' "$(json_escape "$policy_used")"
      printf 'done-gate: assert FAIL — no proof run found (capture something first)\n' >&2
      return 1
    fi
    valid_name "$run" || die "assert: invalid run id"
    ledger="$PROOF_DIR/$run/ledger.jsonl"
    run_label="$run"
    if [ ! -f "$ledger" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"reason":"ledger missing","run":"%s","policy":"%s","checks":[]}\n' "$(json_escape "$run")" "$(json_escape "$policy_used")"
      printf 'done-gate: assert FAIL — no ledger for run=%s\n' "$run" >&2
      return 1
    fi

    # With no explicit/policy labels, assert against the most recent receipt.
    if [ "${#LABELS[@]}" -eq 0 ]; then
      local last; last="$(grep -E '.' "$ledger" | tail -n1 || true)"
      [ -n "$last" ] || { printf 'done-gate: assert FAIL — empty ledger\n' >&2; return 1; }
      local lbl0; lbl0="$(printf '%s' "$last" | sed -E 's/.*"label":"([^"]*)".*/\1/')"
      LABELS=("$lbl0"); LABEL_REGEXES=("$regex")
    fi
  fi

  local now; now="$(epoch)"
  local overall=0 checks="" first=1 idx=0 lbl lrx line ec ep sha cmd fresh cmd_ok line_ok
  local any_pass=0 weak_only=1 warn_label=""
  for lbl in "${LABELS[@]}"; do
    lrx="${LABEL_REGEXES[$idx]:-}"; idx=$((idx + 1))
    if [ "$policy_mode" = "1" ]; then line="$(latest_for_label_global "$lbl")"; else line="$(latest_for_label "$ledger" "$lbl")"; fi
    ec=""; ep=""; sha=""; cmd=""; fresh="false"; cmd_ok="true"; line_ok="false"
    if [ -n "$line" ]; then
      ec="$(rec_exit "$line" || true)"; ep="$(rec_epoch "$line" || true)"
      sha="$(rec_sha "$line" || true)"; cmd="$(rec_command "$line" || true)"
      if [ "${ttl:-0}" -le 0 ] 2>/dev/null; then fresh="true"
      elif [ -n "$ep" ] && [ "$now" -gt 0 ] 2>/dev/null && [ "$((now - ep))" -le "$ttl" ] 2>/dev/null; then fresh="true"; fi
      if [ -n "$lrx" ]; then
        if printf '%s' "$cmd" | grep -Eq "$lrx" 2>/dev/null; then cmd_ok="true"; else cmd_ok="false"; fi
      fi
      if [ "$ec" = "0" ] && [ "$fresh" = "true" ] && [ "$cmd_ok" = "true" ]; then line_ok="true"; fi
    fi
    [ "$line_ok" = "true" ] || overall=1

    # advisory wrong-check bookkeeping (never affects the exit code)
    if [ "$line_ok" = "true" ]; then
      any_pass=1
      if label_is_weak "$lbl"; then warn_label="$lbl"; else weak_only=0; fi
    fi

    if [ "$json" = "1" ]; then
      [ "$first" = "1" ] || checks="$checks,"
      first=0
      checks="$checks{\"label\":\"$(json_escape "$lbl")\",\"found\":$([ -n "$line" ] && echo true || echo false),\"exit_code\":${ec:-null},\"fresh\":$fresh,\"command_allowed\":$cmd_ok,\"sha256\":\"$(json_escape "${sha:-}")\",\"ok\":$line_ok}"
    else
      if [ "$line_ok" = "true" ]; then
        printf 'done-gate: assert OK   label=%s exit=%s fresh=%s\n' "$lbl" "${ec:-?}" "$fresh" >&2
      else
        printf 'done-gate: assert FAIL label=%s found=%s exit=%s fresh=%s command_allowed=%s\n' \
          "$lbl" "$([ -n "$line" ] && echo yes || echo no)" "${ec:-?}" "$fresh" "$cmd_ok" >&2
      fi
    fi
  done

  if [ "$json" = "1" ]; then
    printf '{"ok":%s,"run":"%s","ttl":%s,"policy":"%s","checks":[%s]}\n' \
      "$([ "$overall" = "0" ] && echo true || echo false)" "$(json_escape "$run_label")" "$ttl" "$(json_escape "$policy_used")" "$checks"
  elif [ "$any_pass" = "1" ] && [ "$weak_only" = "1" ]; then
    printf 'done-gate: WARNING — latest proof is %s-only — this may not verify the requested behavior\n' "$warn_label" >&2
  fi
  return "$overall"
}

cmd_verify() {
  local label="" run="" sha="" json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) [ "$#" -ge 2 ] || die "verify: --label requires a value"; label="$2"; shift 2 ;;
      --run)   [ "$#" -ge 2 ] || die "verify: --run requires a value";   run="$2";   shift 2 ;;
      --sha)   [ "$#" -ge 2 ] || die "verify: --sha requires a value";   sha="$2";   shift 2 ;;
      --json)  json=1; shift ;;
      *)       die "verify: unexpected arg '$1'" ;;
    esac
  done
  [ -n "$label" ] || die "verify: --label is required"
  [ -n "$sha" ]   || die "verify: --sha is required"
  run="$(resolve_run_for_read "$run")"
  [ -n "$run" ] || die "verify: no run found (run a capture first or pass --run)"
  valid_name "$run" || die "verify: invalid run id"
  local ledger="$PROOF_DIR/$run/ledger.jsonl"
  [ -f "$ledger" ] || die "verify: no ledger at $ledger"

  local got
  got="$(latest_for_label "$ledger" "$label" | grep -oE '"sha256":"[0-9a-f]+"' | sed -E 's/"sha256":"([0-9a-f]+)"/\1/')"
  local ok="false"
  [ -n "$got" ] && [ "$got" = "$sha" ] && ok="true"

  if [ "$json" = "1" ]; then
    printf '{"ok":%s,"label":"%s","run":"%s","recorded":"%s","expected":"%s"}\n' \
      "$ok" "$(json_escape "$label")" "$(json_escape "$run")" "$(json_escape "${got:-}")" "$(json_escape "$sha")"
  fi
  if [ "$ok" = "true" ]; then
    printf 'done-gate: verify OK label=%s run=%s sha256=%s\n' "$label" "$run" "$got" >&2
    return 0
  fi
  if [ -z "$got" ]; then
    printf 'done-gate: verify FAIL — no record for label=%s in run=%s\n' "$label" "$run" >&2
  else
    printf 'done-gate: verify MISMATCH label=%s run=%s recorded=%s expected=%s\n' "$label" "$run" "$got" "$sha" >&2
  fi
  return 1
}

cmd_show() {
  local run="" json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)  [ "$#" -ge 2 ] || die "show: --run requires a value"; run="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *)      die "show: unexpected arg '$1'" ;;
    esac
  done
  run="$(resolve_run_for_read "$run")"
  [ -n "$run" ] || die "show: no run found"
  valid_name "$run" || die "show: invalid run id"
  local ledger="$PROOF_DIR/$run/ledger.jsonl"
  [ -f "$ledger" ] || die "show: no ledger at $ledger"

  if [ "$json" = "1" ]; then
    local body first=1 ln
    body=""
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      [ "$first" = "1" ] || body="$body,"
      first=0
      body="$body$ln"
    done < "$ledger"
    printf '{"run":"%s","receipts":[%s]}\n' "$(json_escape "$run")" "$body"
  else
    printf '# proof ledger — run=%s\n' "$run"
    cat "$ledger"
  fi
}

usage() {
  sed -n '2,40p' "$0"
}

main() {
  [ "$#" -ge 1 ] || { usage; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    capture) cmd_capture "$@" ;;
    assert)  cmd_assert "$@" ;;
    verify)  cmd_verify "$@" ;;
    show)    cmd_show "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown subcommand '$sub' (capture | assert | verify | show)" ;;
  esac
}

main "$@"
