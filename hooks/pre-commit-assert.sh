#!/usr/bin/env sh
# hooks/pre-commit-assert.sh — pre-commit framework entry point for agent-done-assert.
# pre-commit invokes this with pass_filenames: false, so $@ contains only the
# user-supplied args: values from .pre-commit-config.yaml.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$REPO_ROOT/done-gate.sh" assert "$@"
