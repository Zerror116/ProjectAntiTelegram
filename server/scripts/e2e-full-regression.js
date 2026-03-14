#!/usr/bin/env node

/* eslint-disable no-console */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const SERVER_DIR = path.resolve(__dirname, '..');
const OUTPUT_PATH = path.resolve(
  process.cwd(),
  process.env.E2E_FULL_REGRESSION_REPORT_PATH || 'audit/e2e-full-regression.md',
);

const REQUIRE_FULL = ['1', 'true', 'yes'].includes(
  String(process.env.E2E_REQUIRE_FULL || '').trim().toLowerCase(),
);

function hasEnv(name) {
  return String(process.env[name] || '').trim().length > 0;
}

function hasAll(list) {
  return list.every((name) => hasEnv(name));
}

const checks = [
  {
    id: 'critical',
    title: 'Critical integration',
    command: ['node', 'scripts/critical-integration.js'],
    requiredEnv: ['E2E_BASE_URL', 'E2E_EMAIL', 'E2E_PASSWORD'],
  },
  {
    id: 'phone_access',
    title: 'Phone access e2e',
    command: ['node', 'scripts/e2e-phone-access-flow.js'],
    requiredEnv: ['E2E_BASE_URL', 'E2E_OWNER_EMAIL', 'E2E_OWNER_PASSWORD', 'E2E_DUP_INVITE_CODE'],
  },
  {
    id: 'subscription_guard',
    title: 'Subscription guard e2e',
    command: ['node', 'scripts/e2e-subscription-guard-flow.js'],
    requiredEnv: [
      'E2E_BASE_URL',
      'E2E_CREATOR_EMAIL',
      'E2E_CREATOR_PASSWORD',
      'E2E_STAFF_EMAIL',
      'E2E_STAFF_PASSWORD',
      'E2E_CLIENT_EMAIL',
      'E2E_CLIENT_PASSWORD',
    ],
  },
  {
    id: 'order_pipeline',
    title: 'Order pipeline e2e',
    command: ['node', 'scripts/e2e-order-pipeline-flow.js'],
    requiredEnv: ['E2E_BASE_URL', 'E2E_ADMIN_EMAIL', 'E2E_ADMIN_PASSWORD', 'E2E_CLIENT_EMAIL', 'E2E_CLIENT_PASSWORD'],
  },
  {
    id: 'tenant_isolation',
    title: 'Tenant isolation e2e',
    command: ['node', 'scripts/e2e-tenant-isolation-flow.js'],
    requiredEnv: ['E2E_BASE_URL', 'E2E_TENANT_A_EMAIL', 'E2E_TENANT_A_PASSWORD', 'E2E_TENANT_B_EMAIL', 'E2E_TENANT_B_PASSWORD'],
  },
  {
    id: 'tenant_regression',
    title: 'Tenant isolation regression matrix',
    command: ['node', 'scripts/e2e-tenant-isolation-regression.js'],
    requiredEnv: ['E2E_BASE_URL', 'E2E_TENANT_A_EMAIL', 'E2E_TENANT_A_PASSWORD', 'E2E_TENANT_B_EMAIL', 'E2E_TENANT_B_PASSWORD'],
  },
  {
    id: 'device_limit',
    title: 'Device limit e2e',
    command: ['node', 'scripts/e2e-device-limit-flow.js'],
    requiredEnv: ['E2E_BASE_URL', 'E2E_DEVICE_LIMIT_INVITE_CODE'],
  },
];

const results = [];

function runCheck(check) {
  const missing = check.requiredEnv.filter((name) => !hasEnv(name));
  if (missing.length > 0) {
    results.push({
      id: check.id,
      title: check.title,
      status: 'skip',
      detail: `missing env: ${missing.join(', ')}`,
      durationMs: 0,
      outputTail: '',
    });
    return;
  }

  const started = Date.now();
  const proc = spawnSync(check.command[0], check.command.slice(1), {
    cwd: SERVER_DIR,
    env: process.env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 8,
  });
  const durationMs = Date.now() - started;

  const mergedOutput = `${proc.stdout || ''}${proc.stderr || ''}`.trim();
  const tailLines = mergedOutput
    .split(/\r?\n/)
    .slice(-12)
    .join('\n')
    .trim();

  if (proc.status === 0) {
    const skippedInOutput = /\bSKIP\b/i.test(mergedOutput);
    results.push({
      id: check.id,
      title: check.title,
      status: skippedInOutput ? 'skip' : 'pass',
      detail: skippedInOutput ? 'script reported SKIP' : 'ok',
      durationMs,
      outputTail: tailLines,
    });
    return;
  }

  results.push({
    id: check.id,
    title: check.title,
    status: 'fail',
    detail: `exit=${proc.status ?? 'unknown'}`,
    durationMs,
    outputTail: tailLines,
  });
}

function buildReport() {
  const pass = results.filter((r) => r.status === 'pass').length;
  const fail = results.filter((r) => r.status === 'fail').length;
  const skip = results.filter((r) => r.status === 'skip').length;

  const lines = [];
  lines.push('# E2E Full Regression Report');
  lines.push('');
  lines.push(`- Generated at: ${new Date().toISOString()}`);
  lines.push(`- Require full mode: ${REQUIRE_FULL}`);
  lines.push(`- Summary: pass=${pass}, fail=${fail}, skip=${skip}`);
  lines.push('');
  lines.push('## Results');
  lines.push('');

  for (const row of results) {
    const badge = row.status === 'pass' ? 'PASS' : row.status === 'skip' ? 'SKIP' : 'FAIL';
    lines.push(
      `- [${badge}] ${row.id} — ${row.title} (${row.detail}, ${row.durationMs}ms)`,
    );
  }

  lines.push('');
  lines.push('## Output Tail');
  lines.push('');
  for (const row of results) {
    lines.push(`### ${row.id}`);
    lines.push('```text');
    lines.push(row.outputTail || '(empty output)');
    lines.push('```');
    lines.push('');
  }

  return lines.join('\n');
}

function saveReport(markdown) {
  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  fs.writeFileSync(OUTPUT_PATH, markdown, 'utf8');
  console.log(`full regression report: ${OUTPUT_PATH}`);
}

function main() {
  for (const check of checks) {
    console.log(`\n==> ${check.id}: ${check.title}`);
    runCheck(check);
  }

  const report = buildReport();
  saveReport(report);

  const failed = results.filter((r) => r.status === 'fail').length;
  const skipped = results.filter((r) => r.status === 'skip').length;
  if (failed > 0) {
    process.exit(1);
  }
  if (REQUIRE_FULL && skipped > 0) {
    process.exit(1);
  }
}

main();
