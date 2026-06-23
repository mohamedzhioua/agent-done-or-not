#!/usr/bin/env node
// agent-done-or-not - thin npm wrapper. It forwards CLI args to the bundled
// engine, preserves the caller's cwd (so .agent-proof/ lands in their repo),
// and exits with the engine's own exit code. Zero dependencies.
'use strict';

const path = require('path');
const { spawnSync } = require('child_process');

const pkgRoot = path.join(__dirname, '..');
const bashGate = path.join(pkgRoot, 'done-gate.sh');
const psGate = path.join(pkgRoot, 'done-gate.ps1');
const args = process.argv.slice(2);

function run(command, commandArgs) {
  return spawnSync(command, commandArgs, {
    stdio: 'inherit',
    cwd: process.cwd(),
  });
}

function finish(result) {
  if (result.error) {
    if (result.error.code === 'ENOENT') {
      return false;
    }
    process.stderr.write('agent-done-or-not: ' + result.error.message + '\n');
    process.exit(1);
  }

  if (result.signal) {
    process.exit(1);
  }

  process.exit(result.status === null ? 1 : result.status);
}

const bashResult = run('bash', [bashGate, ...args]);
if (finish(bashResult) !== false) {
  process.exit(1);
}

if (process.platform === 'win32') {
  for (const shell of ['pwsh', 'powershell']) {
    const psResult = run(shell, [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      psGate,
      ...args,
    ]);
    if (finish(psResult) !== false) {
      process.exit(1);
    }
  }
}

process.stderr.write(
  "agent-done-or-not: no supported shell found. Install bash, or on Windows install/use PowerShell.\n"
);
process.exit(127);
