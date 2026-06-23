#!/usr/bin/env node
// agent-done-or-not - thin npm wrapper. It forwards CLI args to the bundled
// engine, preserves the caller's cwd (so .agent-proof/ lands in their repo),
// and exits with the engine's own exit code. Zero dependencies.
'use strict';

const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

const pkgRoot = path.join(__dirname, '..');
const bashGate = path.join(pkgRoot, 'done-gate.sh');
const psGate = path.join(pkgRoot, 'done-gate.ps1');
const args = process.argv.slice(2);
const proofStart = '<!-- agent-done-or-not:start -->';
const proofEnd = '<!-- agent-done-or-not:end -->';

function printHelp() {
  process.stdout.write(`agent-done-or-not

Usage:
  agent-done-or-not init [--dry-run] [--yes] [--claude-hook] [--label name --command "cmd"]
  agent-done-or-not report [--format markdown|html|json]
  agent-done-or-not capture --label check -- <command>
  agent-done-or-not assert [--label check] [--ttl seconds]

Commands other than init/report are forwarded to the bundled proof gate.
`);
}

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

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
}

function fileExists(file) {
  try {
    return fs.existsSync(file);
  } catch (_) {
    return false;
  }
}

function chooseNodeRunner(cwd) {
  if (fileExists(path.join(cwd, 'pnpm-lock.yaml'))) return 'pnpm';
  if (fileExists(path.join(cwd, 'yarn.lock'))) return 'yarn';
  return 'npm';
}

function nodeCommand(runner, scriptName) {
  if (runner === 'yarn') return `yarn ${scriptName}`;
  return `${runner} run ${scriptName}`;
}

function detectChecks(cwd) {
  const commandIndex = args.indexOf('--command');
  const labelIndex = args.indexOf('--label');
  if (commandIndex !== -1 && args[commandIndex + 1]) {
    return [{ label: labelIndex !== -1 && args[labelIndex + 1] ? args[labelIndex + 1] : 'check', command: args[commandIndex + 1] }];
  }

  const checks = [];
  const pkg = readJson(path.join(cwd, 'package.json'));
  if (pkg && pkg.scripts && typeof pkg.scripts === 'object') {
    const runner = chooseNodeRunner(cwd);
    for (const label of ['test', 'build', 'lint']) {
      if (typeof pkg.scripts[label] === 'string') {
        checks.push({ label, command: nodeCommand(runner, label) });
      }
    }
  }

  if (fileExists(path.join(cwd, 'pyproject.toml')) ||
      fileExists(path.join(cwd, 'pytest.ini')) ||
      fileExists(path.join(cwd, 'tox.ini')) ||
      fileExists(path.join(cwd, 'setup.cfg'))) {
    checks.push({ label: 'test', command: 'python -m pytest' });
  }
  if (fileExists(path.join(cwd, 'go.mod'))) checks.push({ label: 'test', command: 'go test ./...' });
  if (fileExists(path.join(cwd, 'Cargo.toml'))) checks.push({ label: 'test', command: 'cargo test' });
  if (fileExists(path.join(cwd, 'pom.xml'))) checks.push({ label: 'test', command: 'mvn test' });
  if (fileExists(path.join(cwd, 'build.gradle')) || fileExists(path.join(cwd, 'build.gradle.kts'))) {
    checks.push({ label: 'test', command: fileExists(path.join(cwd, 'gradlew')) ? './gradlew test' : 'gradle test' });
  }

  if (checks.length === 0) {
    checks.push({ label: 'check', command: '<your verifying command>' });
  }
  return checks;
}

function proofBlock(checks) {
  const first = checks[0];
  const lines = [
    proofStart,
    '## Proof Of Done',
    '',
    'Before reporting a task complete, run the verifying command through the proof gate and only claim done after a passing receipt.',
    '',
    '```bash',
    `npx agent-done-or-not capture --label ${first.label} -- ${first.command}`,
    '```',
    '',
    'Suggested checks:'
  ];
  for (const check of checks) {
    lines.push(`- \`${check.label}\`: \`${check.command}\``);
  }
  lines.push('', 'If a check fails, fix the issue and capture again. Do not report success from a failing or stale receipt.', proofEnd, '');
  return lines.join('\n');
}

// Never overwrite an existing backup: a same-second re-run would otherwise
// clobber the only copy of the user's original content.
function writeBackup(file, content) {
  const stamp = new Date().toISOString().replace(/[-:TZ.]/g, '').slice(0, 14);
  const base = `${file}.agent-done-or-not.bak-${stamp}`;
  let backup = base;
  let n = 1;
  while (fileExists(backup)) backup = `${base}-${n++}`;
  fs.writeFileSync(backup, content);
}

function patchInstructionFile(file, block, dryRun, touched) {
  let current = '';
  if (fileExists(file)) current = fs.readFileSync(file, 'utf8');
  let next;
  if (current.includes(proofStart) && current.includes(proofEnd)) {
    const before = current.slice(0, current.indexOf(proofStart));
    const after = current.slice(current.indexOf(proofEnd) + proofEnd.length);
    // Preserve a newline between the managed block and following content so
    // repeated `init` runs cannot glue the end marker to the next line.
    const tail = after.replace(/^\n*/, after.trim() ? '\n' : '');
    next = before + block.trimEnd() + tail;
  } else {
    next = current.trimEnd() + (current.trim() ? '\n\n' : '') + block;
  }

  if (next !== current) {
    touched.push(path.relative(process.cwd(), file) || path.basename(file));
    if (!dryRun) {
      if (current) writeBackup(file, current);
      fs.writeFileSync(file, next);
    }
  }
}

function writeClaudeHook(cwd, dryRun, touched) {
  const settingsFile = path.join(cwd, '.claude', 'settings.json');
  const settings = readJson(settingsFile) || {};
  const command = process.platform === 'win32'
    ? 'powershell -NoProfile -File "$env:CLAUDE_PROJECT_DIR\\stop-gate.ps1"'
    : 'bash "$CLAUDE_PROJECT_DIR/stop-gate.sh"';
  settings.hooks = settings.hooks || {};
  settings.hooks.Stop = settings.hooks.Stop || [];
  const exists = JSON.stringify(settings.hooks.Stop).includes('stop-gate.');
  if (!exists) {
    settings.hooks.Stop.push({ hooks: [{ type: 'command', command }] });
    touched.push(path.relative(cwd, settingsFile));
    if (!dryRun) writeJson(settingsFile, settings);
  }
}

function runInit() {
  const dryRun = args.includes('--dry-run');
  const claudeHook = args.includes('--claude-hook');
  const cwd = process.cwd();
  const checks = detectChecks(cwd);
  const targets = ['AGENTS.md', 'CLAUDE.md', '.cursorrules', '.windsurfrules', '.clinerules']
    .map((name) => path.join(cwd, name))
    .filter((file) => fileExists(file));
  if (targets.length === 0) targets.push(path.join(cwd, 'AGENTS.md'));

  const touched = [];
  const block = proofBlock(checks);
  for (const target of targets) patchInstructionFile(target, block, dryRun, touched);
  if (claudeHook) writeClaudeHook(cwd, dryRun, touched);

  const first = checks[0];
  process.stdout.write(`${dryRun ? 'Would update' : 'Updated'}: ${touched.length ? touched.join(', ') : '(nothing)'}\n`);
  process.stdout.write(`Next capture command:\n  npx agent-done-or-not capture --label ${first.label} -- ${first.command}\n`);
  if (!claudeHook) process.stdout.write('Add --claude-hook to generate a Claude Code Stop hook config.\n');
}

// Receipt fields (notably `command` and `label`) are agent-controlled, so they
// must be neutralized before rendering into a markdown table or HTML.
function mdCell(value) {
  return String(value == null ? '' : value)
    .replace(/\\/g, '\\\\')
    .replace(/\|/g, '\\|')
    .replace(/`/g, '\\`')
    .replace(/\r?\n/g, ' ');
}

function htmlCell(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function gitValue(argsForGit) {
  const result = spawnSync('git', argsForGit, { cwd: process.cwd(), encoding: 'utf8' });
  if (result.status !== 0) return null;
  return String(result.stdout || '').trim();
}

function listLedgerFiles(dir) {
  const out = [];
  if (!fileExists(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const ledger = path.join(dir, entry.name, 'ledger.jsonl');
    if (fileExists(ledger)) out.push(ledger);
  }
  return out;
}

function readReceipts() {
  const proofDir = process.env.AGENT_DONE_DIR || path.join(process.cwd(), '.agent-proof');
  const receipts = [];
  for (const ledger of listLedgerFiles(proofDir)) {
    const lines = fs.readFileSync(ledger, 'utf8').split(/\r?\n/).filter(Boolean);
    for (const line of lines) {
      try {
        const receipt = JSON.parse(line);
        receipt.ledger = path.relative(process.cwd(), ledger);
        receipts.push(receipt);
      } catch (_) {}
    }
  }
  receipts.sort((a, b) => Number(b.epoch || 0) - Number(a.epoch || 0));
  return receipts;
}

function reportState(receipts) {
  if (process.env.AGENT_DONE_OFF === '1') return 'bypassed';
  if (receipts.length === 0) return 'missing';
  if (Number(receipts[0].exit_code) !== 0) return 'failed';
  const ttl = Number(process.env.AGENT_DONE_TTL || 3600);
  const epoch = Number(receipts[0].epoch || 0);
  if (ttl > 0 && epoch > 0 && Math.floor(Date.now() / 1000) - epoch > ttl) return 'stale';
  return 'local-only';
}

function runReport() {
  let format = 'markdown';
  const formatIndex = args.indexOf('--format');
  if (formatIndex !== -1 && args[formatIndex + 1]) format = args[formatIndex + 1];
  const receipts = readReceipts();
  const state = reportState(receipts);
  const commit = gitValue(['rev-parse', '--short', 'HEAD']);
  const dirty = gitValue(['status', '--porcelain']);
  const payload = {
    state,
    commit,
    dirty: dirty === null ? null : dirty.length > 0,
    bypass: process.env.AGENT_DONE_OFF === '1',
    receipts: receipts.slice(0, 20),
  };

  if (format === 'json') {
    process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
    return;
  }

  const top = receipts.slice(0, 10);
  const rows = top.map((r) =>
    `| ${mdCell(r.label)} | ${mdCell(r.exit_code)} | ${mdCell(r.sha256)} | ${mdCell(r.command)} | ${mdCell(r.ledger)} |`
  );
  const markdown = [
    '# Proof Report',
    '',
    `State: **${state}**`,
    `Commit: ${commit || 'unknown'}`,
    `Dirty tree: ${payload.dirty === null ? 'unknown' : payload.dirty ? 'yes' : 'no'}`,
    `Bypass: ${payload.bypass ? 'yes' : 'no'}`,
    '',
    '| Label | Exit | SHA-256 | Command | Ledger |',
    '|---|---:|---|---|---|',
    ...(rows.length ? rows : ['| - | - | - | no receipts found | - |']),
    ''
  ].join('\n');

  if (format === 'html') {
    const cells = top.map((r) =>
      `    <tr><td>${htmlCell(r.label)}</td><td>${htmlCell(r.exit_code)}</td><td><code>${htmlCell(r.sha256)}</code></td><td><code>${htmlCell(r.command)}</code></td><td>${htmlCell(r.ledger)}</td></tr>`
    );
    const html = [
      '<!doctype html><meta charset="utf-8"><title>Proof Report</title>',
      '<h1>Proof Report</h1>',
      `<p>State: <strong>${htmlCell(state)}</strong></p>`,
      `<p>Commit: ${htmlCell(commit || 'unknown')}</p>`,
      `<p>Dirty tree: ${payload.dirty === null ? 'unknown' : payload.dirty ? 'yes' : 'no'}</p>`,
      `<p>Bypass: ${payload.bypass ? 'yes' : 'no'}</p>`,
      '<table>',
      '  <thead><tr><th>Label</th><th>Exit</th><th>SHA-256</th><th>Command</th><th>Ledger</th></tr></thead>',
      '  <tbody>',
      ...(cells.length ? cells : ['    <tr><td colspan="5">no receipts found</td></tr>']),
      '  </tbody>',
      '</table>',
      ''
    ].join('\n');
    process.stdout.write(html);
    return;
  }
  if (format !== 'markdown') {
    process.stderr.write('agent-done-or-not: --format must be markdown, html, or json\n');
    process.exit(2);
  }
  process.stdout.write(markdown);
}

if (args.length === 0 || args[0] === '--help' || args[0] === '-h' || args[0] === 'help') {
  printHelp();
  process.exit(0);
}

if (args[0] === 'init') {
  runInit();
  process.exit(0);
}

if (args[0] === 'report') {
  runReport();
  process.exit(0);
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
