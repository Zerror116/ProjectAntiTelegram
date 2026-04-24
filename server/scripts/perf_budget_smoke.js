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
  const queueHealthQ = await db.query(
    `SELECT
       COUNT(*) FILTER (
         WHERE channel = 'push'
           AND queue_name = 'push'
           AND state IN ('queued', 'failed')
           AND COALESCE(next_attempt_at, now()) <= now()
       )::int AS ready_count,
       COALESCE(
         MAX(EXTRACT(EPOCH FROM (now() - created_at)))
         FILTER (
           WHERE channel = 'push'
             AND queue_name = 'push'
             AND state IN ('queued', 'failed')
             AND COALESCE(next_attempt_at, now()) <= now()
         ),
         0
       )::int AS oldest_ready_age_seconds,
       COALESCE(
         AVG(EXTRACT(EPOCH FROM (COALESCE(delivered_at, sent_at, updated_at) - created_at)) * 1000)
         FILTER (
           WHERE channel = 'push'
             AND created_at >= now() - interval '30 minutes'
             AND COALESCE(delivered_at, sent_at, updated_at) >= now() - interval '15 minutes'
             AND state IN ('sent', 'provider_accepted', 'delivered', 'opened')
         ),
         0
       )::int AS recent_delivery_latency_ms
     FROM notification_deliveries`,
  );
  const endpointHealthQ = await db.query(
    `SELECT
       COUNT(*) FILTER (
         WHERE is_active = true
           AND COALESCE(consecutive_failures, 0) > 0
       )::int AS active_failing_endpoints
     FROM notification_endpoints`,
  );
  const queueHealth = queueHealthQ.rows?.[0] || {};
  const endpointHealth = endpointHealthQ.rows?.[0] || {};
  const metrics = {
    web_main_dart_js_bytes: statSize(path.join(buildWebDir, 'main.dart.js')),
    web_flutter_js_bytes: statSize(path.join(buildWebDir, 'flutter.js')),
    web_service_worker_bytes: statSize(path.join(buildWebDir, 'flutter_service_worker.js')),
    notification_queue_ready_count:
      Number(queueHealth.ready_count || 0) || 0,
    notification_queue_oldest_ready_age_seconds:
      Number(queueHealth.oldest_ready_age_seconds || 0) || 0,
    notification_recent_delivery_latency_ms:
      Number(queueHealth.recent_delivery_latency_ms || 0) || 0,
    notification_active_failing_endpoints:
      Number(endpointHealth.active_failing_endpoints || 0) || 0,
  };
  const budget = {
    web_main_dart_js_bytes: Number(process.env.PERF_BUDGET_MAIN_DART_JS_BYTES || 16 * 1024 * 1024),
    web_flutter_js_bytes: Number(process.env.PERF_BUDGET_FLUTTER_JS_BYTES || 1024 * 1024),
    web_service_worker_bytes: Number(process.env.PERF_BUDGET_SERVICE_WORKER_BYTES || 512 * 1024),
    notification_queue_ready_count:
      Number(process.env.PERF_BUDGET_NOTIFICATION_QUEUE_READY || 250),
    notification_queue_oldest_ready_age_seconds:
      Number(process.env.PERF_BUDGET_NOTIFICATION_OLDEST_READY_SECONDS || 300),
    notification_recent_delivery_latency_ms:
      Number(process.env.PERF_BUDGET_NOTIFICATION_LATENCY_MS || 30000),
    notification_active_failing_endpoints:
      Number(process.env.PERF_BUDGET_ACTIVE_FAILING_ENDPOINTS || 100),
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
