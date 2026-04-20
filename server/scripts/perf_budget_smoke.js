#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const db = require('../src/db');

function statSize(filePath) {
  try {
    return fs.statSync(filePath).size;
  } catch (_) {
    return null;
  }
}

async function main() {
  const root = path.resolve(__dirname, '..', '..');
  const buildWebDir = path.join(root, 'build', 'web');
  const metrics = {
    web_main_dart_js_bytes: statSize(path.join(buildWebDir, 'main.dart.js')),
    web_flutter_js_bytes: statSize(path.join(buildWebDir, 'flutter.js')),
    web_service_worker_bytes: statSize(path.join(buildWebDir, 'flutter_service_worker.js')),
  };
  const budget = {
    web_main_dart_js_bytes: Number(process.env.PERF_BUDGET_MAIN_DART_JS_BYTES || 16 * 1024 * 1024),
    web_flutter_js_bytes: Number(process.env.PERF_BUDGET_FLUTTER_JS_BYTES || 1024 * 1024),
    web_service_worker_bytes: Number(process.env.PERF_BUDGET_SERVICE_WORKER_BYTES || 512 * 1024),
  };
  const failures = Object.entries(budget).filter(([key, limit]) => {
    const value = metrics[key];
    return Number.isFinite(value) && value > limit;
  });

  await db.query(
    `INSERT INTO performance_budget_reports (scope, target_id, metrics, budget, status, created_at)
     VALUES ($1, $2, $3::jsonb, $4::jsonb, $5, now())`,
    [
      'web_bundle',
      'build/web',
      JSON.stringify(metrics),
      JSON.stringify(budget),
      failures.length > 0 ? 'fail' : 'pass',
    ],
  );

  console.log(JSON.stringify({ metrics, budget, failures }, null, 2));
  if (failures.length > 0) {
    process.exit(2);
  }
}

main()
  .catch((err) => {
    console.error('[perf_budget_smoke] failed', err);
    process.exitCode = 1;
  })
  .finally(async () => {
    try {
      await db.pool.end();
    } catch (_) {}
    setImmediate(() => process.exit(process.exitCode || 0));
  });
