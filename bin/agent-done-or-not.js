#!/usr/bin/env node
// agent-done-or-not — thin npm wrapper. The canonical engine is the bundled
// done-gate.sh; this shim just forwards all CLI args to `bash done-gate.sh`,
// preserves the caller's cwd (so .agent-proof/ lands in their repo), and exits
// with bash's own exit code. Zero dependencies (Node built-ins only).
'use strict';

const path = require('path');
const { spawnSync } = require('child_process');

const pkgRoot = path.join(__dirname, '..');
const gate = path.join(pkgRoot, 'done-gate.sh');
const args = process.argv.slice(2);

const result = spawnSync('bash', [gate, ...args], {
  stdio: 'inherit',
  cwd: process.cwd(),
});

if (result.error) {
  if (result.error.code === 'ENOENT') {
    process.stderr.write(
      "agent-done-or-not: 'bash' not found on PATH. Install bash (on Windows, Git Bash) and retry.\n"
    );
    process.exit(127);
  }
  process.stderr.write('agent-done-or-not: ' + result.error.message + '\n');
  process.exit(1);
}

if (result.signal) {
  process.exit(1);
}

process.exit(result.status === null ? 1 : result.status);
