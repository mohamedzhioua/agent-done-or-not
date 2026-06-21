#!/usr/bin/env bash
# done-gate.sh — proof receipts for AI coding agents.
#
# Your agent says "done." This makes it prove it. `capture` runs your real
# check, hashes the output, and records the command + exit code + SHA-256 in a
# tamper-evident ledger. Because capture EXITS WITH THE COMMAND'S OWN CODE, a
# failing check fails the receipt — green cannot be faked.
#
# Pairs with stop-gate.sh, which blocks an agent from ending its turn unless a
# fresh PASSING receipt exists. Works with Claude Code, Cursor, and Codex.
#
# Subcommands:
#   capture --label L [--run R] -- CMD [ARGS...]
#       Run CMD, stream its output to the console AND a log file, then append a
#       JSONL receipt (label, command, exit_code, sha256, log, at, session).
#       Updates the latest-run pointer. Exits with CMD's own exit code.
#
#   verify --label L [--run R] --sha HEX
#       Exit 0 iff the ledger's recorded sha256 for L equals HEX. The proof
#       step: a claimed result is only trusted when the hash matches.
#
#   show [--run R]
#       Print the ledger for the run (newest run if --run is omitted).
#
# Receipts live under .agent-proof/<run>/ (add .agent-proof/ to .gitignore).
# The run id defaults to $AGENT_DONE_SESSION (so receipts segregate per agent
# session when the harness exports it), else a UTC timestamp.
#
# Dependency-free: SHA via sha256sum | shasum -a 256 | python hashlib; the
# ledger is hand-written JSONL. No network, no LLM, no extra tooling.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROOF_DIR="${AGENT_DONE_DIR:-$ROOT/.agent-proof}"

die() { printf 'done-gate: %s\n' "$1" >&2; exit 2; }

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }
run_stamp()  { date -u +%Y%m%dT%H%M%SZ    2>/dev/null || printf 'run'; }

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

cmd_capture() {
  local label="" run="" ; local -a CMD=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --run)   run="$2";   shift 2 ;;
      --)      shift; CMD=("$@"); break ;;
      *)       die "capture: unexpected arg '$1' (did you forget '--' before the command?)" ;;
    esac
  done
  [ -n "$label" ] || die "capture: --label is required"
  [ "${#CMD[@]}" -ge 1 ] || die "capture: a command after '--' is required"

  run="${run:-${AGENT_DONE_SESSION:-$(run_stamp)}}"
  local dir="$PROOF_DIR/$run"
  mkdir -p "$dir"
  local log="$dir/$label.log"

  # Run the command, mirroring output to console + log. PIPESTATUS[0] keeps the
  # command's real exit code (tee would otherwise mask it).
  local rc
  set +e
  ( "${CMD[@]}" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  local sha; sha="$(sha256_of_file "$log")"
  printf '{"label":"%s","command":"%s","exit_code":%s,"sha256":"%s","log":"%s","at":"%s","session":"%s"}\n' \
    "$(json_escape "$label")" "$(json_escape "${CMD[*]}")" "$rc" "$sha" \
    "$(json_escape "${log#"$ROOT/"}")" "$(timestamp)" \
    "$(json_escape "${AGENT_DONE_SESSION:-}")" >> "$dir/ledger.jsonl"

  # Atomic latest-run pointer so a concurrent capture can't leave a torn file
  # that a parallel verify/show would read.
  printf '%s\n' "$run" > "$PROOF_DIR/latest.$$.tmp" && mv -f "$PROOF_DIR/latest.$$.tmp" "$PROOF_DIR/latest"

  printf 'done-gate: captured label=%s run=%s exit=%s sha256=%s\n' "$label" "$run" "$rc" "$sha" >&2
  return "$rc"
}

cmd_verify() {
  local label="" run="" sha=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --run)   run="$2";   shift 2 ;;
      --sha)   sha="$2";   shift 2 ;;
      *)       die "verify: unexpected arg '$1'" ;;
    esac
  done
  [ -n "$label" ] || die "verify: --label is required"
  [ -n "$sha" ]   || die "verify: --sha is required"
  run="$(resolve_run_for_read "$run")"
  [ -n "$run" ] || die "verify: no run found (run a capture first or pass --run)"
  local ledger="$PROOF_DIR/$run/ledger.jsonl"
  [ -f "$ledger" ] || die "verify: no ledger at $ledger"

  # Match the label as a fixed string (-F): a label with regex metacharacters
  # must match the literal ledger field. Require a sha256 on the line so a
  # non-matching line can't fall through as a spurious hit.
  local got
  got="$(grep -F "\"label\":\"$(json_escape "$label")\"" "$ledger" | tail -n1 \
        | grep -oE '"sha256":"[0-9a-f]+"' | sed -E 's/"sha256":"([0-9a-f]+)"/\1/')"
  if [ -z "$got" ]; then
    printf 'done-gate: verify FAIL — no record for label=%s in run=%s\n' "$label" "$run" >&2
    return 1
  fi
  if [ "$got" = "$sha" ]; then
    printf 'done-gate: verify OK label=%s run=%s sha256=%s\n' "$label" "$run" "$got" >&2
    return 0
  fi
  printf 'done-gate: verify MISMATCH label=%s run=%s recorded=%s expected=%s\n' \
    "$label" "$run" "$got" "$sha" >&2
  return 1
}

cmd_show() {
  local run=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run) run="$2"; shift 2 ;;
      *)     die "show: unexpected arg '$1'" ;;
    esac
  done
  run="$(resolve_run_for_read "$run")"
  [ -n "$run" ] || die "show: no run found"
  local ledger="$PROOF_DIR/$run/ledger.jsonl"
  [ -f "$ledger" ] || die "show: no ledger at $ledger"
  printf '# proof ledger — run=%s\n' "$run"
  cat "$ledger"
}

usage() {
  sed -n '2,38p' "$0"
}

main() {
  [ "$#" -ge 1 ] || { usage; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    capture) cmd_capture "$@" ;;
    verify)  cmd_verify "$@" ;;
    show)    cmd_show "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown subcommand '$sub' (capture | verify | show)" ;;
  esac
}

main "$@"
