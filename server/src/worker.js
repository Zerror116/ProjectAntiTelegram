const fs = require('fs');
const path = require('path');
const dotenv = require('dotenv');

const serverRoot = path.resolve(__dirname, '..');
dotenv.config({ path: path.join(serverRoot, '.env') });

const bootNodeEnv = String(process.env.NODE_ENV || 'development').toLowerCase().trim();
if (bootNodeEnv !== 'production') {
  const localEnvPath = path.join(serverRoot, '.env.local');
  if (fs.existsSync(localEnvPath)) {
    dotenv.config({ path: localEnvPath, override: true });
  }
}

const { bootstrapDatabase } = require('./utils/bootstrap');
const db = require('./db');
const { ensureStorageLayout } = require('./utils/storagePaths');
const { ensurePlaceholderAssets } = require('./utils/uploadRecovery');
const { refreshMediaAssetCache } = require('./utils/mediaAssets');
const { runNotificationDigestSweep } = require('./utils/notifications');
const {
  processNotificationQueueBatch,
  sweepDisabledEndpoints,
} = require('./utils/notificationQueue');
const {
  loadTenantProcessingScopes,
  runInTenantProcessingScope,
  scopeLabel,
} = require('./utils/tenantProcessingScopes');
const { logMonitoringEvent } = require('./utils/monitoring');

const WORKER_ID = process.env.FENIX_WORKER_ID || `${process.pid}`;
const POLL_INTERVAL_MS = Math.max(1000, Number.parseInt(process.env.NOTIFICATION_WORKER_POLL_MS || '4000', 10) || 4000);
const IDLE_INTERVAL_MS = Math.max(POLL_INTERVAL_MS, Number.parseInt(process.env.NOTIFICATION_WORKER_IDLE_MS || '12000', 10) || 12000);
const BATCH_LIMIT = Math.max(1, Math.min(Number.parseInt(process.env.NOTIFICATION_WORKER_BATCH_LIMIT || '25', 10) || 25, 100));
const DIGEST_SWEEP_INTERVAL_MS = Math.max(60_000, Number.parseInt(process.env.NOTIFICATION_DIGEST_SWEEP_MS || `${5 * 60 * 1000}`, 10) || 5 * 60 * 1000);
const ENDPOINT_SWEEP_INTERVAL_MS = Math.max(60_000, Number.parseInt(process.env.NOTIFICATION_ENDPOINT_SWEEP_MS || `${15 * 60 * 1000}`, 10) || 15 * 60 * 1000);

let stopping = false;
let digestTimer = null;
let endpointSweepTimer = null;
let digestSweepInFlight = false;
let endpointSweepInFlight = false;

async function reportWorkerError(code, error, details = {}) {
  const message = String(error?.message || error || code);
  console.error(`[worker] ${code}:`, error);
  try {
    await logMonitoringEvent({
      queryable: db,
      scope: 'process',
      subsystem: 'notifications',
      level: 'error',
      code,
      source: 'server/src/worker.js',
      message,
      details: {
        worker_id: WORKER_ID,
        stack: String(error?.stack || '').trim() || null,
        ...details,
      },
    });
  } catch (monitoringError) {
    console.error('[worker] monitoring log failed:', monitoringError);
  }
}

async function runDigestSweep(reason) {
  const scopes = await loadTenantProcessingScopes();
  let completed = 0;
  for (const scope of scopes) {
    const label = scopeLabel(scope);
    try {
      await runInTenantProcessingScope(scope, () => runNotificationDigestSweep());
      completed += 1;
    } catch (error) {
      await reportWorkerError('notification_digest_worker_error', error, {
        reason,
        tenant_code: label === 'platform' ? null : label,
      });
    }
  }
  console.log(`[worker] digest sweep completed (${reason}, scopes=${completed}/${scopes.length})`);
}

async function runDigestSweepOnce(reason) {
  if (digestSweepInFlight) {
    console.warn(`[worker] digest sweep skipped (${reason}): previous sweep still running`);
    return;
  }
  digestSweepInFlight = true;
  try {
    await runDigestSweep(reason);
  } finally {
    digestSweepInFlight = false;
  }
}

async function runEndpointSweep(reason) {
  const scopes = await loadTenantProcessingScopes();
  let disabled = 0;
  let completed = 0;
  for (const scope of scopes) {
    const label = scopeLabel(scope);
    try {
      disabled += await runInTenantProcessingScope(scope, () => sweepDisabledEndpoints());
      completed += 1;
    } catch (error) {
      await reportWorkerError('notification_endpoint_sweep_error', error, {
        reason,
        tenant_code: label === 'platform' ? null : label,
      });
    }
  }
  try {
    if (disabled > 0) {
      console.log(`[worker] disabled stale endpoints=${disabled} (${reason}, scopes=${completed}/${scopes.length})`);
    }
  } catch (error) {
    await reportWorkerError('notification_endpoint_sweep_error', error, { reason });
  }
}

async function runEndpointSweepOnce(reason) {
  if (endpointSweepInFlight) {
    console.warn(`[worker] endpoint sweep skipped (${reason}): previous sweep still running`);
    return;
  }
  endpointSweepInFlight = true;
  try {
    await runEndpointSweep(reason);
  } finally {
    endpointSweepInFlight = false;
  }
}

async function processNotificationQueueAcrossScopes() {
  const scopes = await loadTenantProcessingScopes();
  const processed = [];
  for (const scope of scopes) {
    const label = scopeLabel(scope);
    try {
      const scopedProcessed = await runInTenantProcessingScope(scope, () =>
        processNotificationQueueBatch({
          limit: BATCH_LIMIT,
          workerId: label === 'platform' ? WORKER_ID : `${WORKER_ID}:${label}`,
        }),
      );
      if (Array.isArray(scopedProcessed) && scopedProcessed.length > 0) {
        processed.push(...scopedProcessed);
        console.log(`[worker] processed deliveries=${scopedProcessed.length} scope=${label}`);
      }
    } catch (error) {
      await reportWorkerError('notification_worker_scope_error', error, {
        tenant_code: label === 'platform' ? null : label,
      });
    }
  }
  return processed;
}

async function workerLoop() {
  while (!stopping) {
    try {
      const processed = await processNotificationQueueAcrossScopes();
      const count = Array.isArray(processed) ? processed.length : 0;
      await new Promise((resolve) => setTimeout(resolve, count > 0 ? POLL_INTERVAL_MS : IDLE_INTERVAL_MS));
    } catch (error) {
      await reportWorkerError('notification_worker_loop_error', error);
      await new Promise((resolve) => setTimeout(resolve, IDLE_INTERVAL_MS));
    }
  }
}

async function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`[worker] ${signal} received, shutting down`);
  if (digestTimer) clearInterval(digestTimer);
  if (endpointSweepTimer) clearInterval(endpointSweepTimer);
  setTimeout(() => process.exit(0), 250).unref();
}

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('unhandledRejection', (reason) => {
  void reportWorkerError('notification_worker_unhandled_rejection', reason);
});
process.on('uncaughtException', (error) => {
  void reportWorkerError('notification_worker_uncaught_exception', error).finally(() => {
    process.exit(1);
  });
});

(async () => {
  try {
    console.log('[worker] starting notification worker');
    ensureStorageLayout();
    ensurePlaceholderAssets(process.env.PUBLIC_BASE_URL || 'http://localhost');
    const bootstrap = await bootstrapDatabase();
    console.log(`[worker] bootstrap applied=${bootstrap.applied.length}`);
    await refreshMediaAssetCache();
    await runDigestSweepOnce('startup');
    await runEndpointSweepOnce('startup');
    digestTimer = setInterval(() => {
      void runDigestSweepOnce('interval');
    }, DIGEST_SWEEP_INTERVAL_MS);
    endpointSweepTimer = setInterval(() => {
      void runEndpointSweepOnce('interval');
    }, ENDPOINT_SWEEP_INTERVAL_MS);
    await workerLoop();
  } catch (error) {
    await reportWorkerError('notification_worker_boot_error', error);
    process.exit(1);
  }
})();
