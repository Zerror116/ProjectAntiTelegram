const db = require("../db");
const {
  MESSAGE_ENCRYPTION_PREFIX,
  encryptMessageText,
  decryptMessageText,
  isEncryptedMessageText,
  getEncryptedMessageVersion,
  getCurrentMessageKeyVersion,
} = require("./messageCrypto");

function toPositiveInt(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.floor(parsed);
  if (normalized <= 0) return fallback;
  return normalized;
}

function toBool(value, fallback = false) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  if (!normalized) return fallback;
  return normalized === "1" || normalized === "true" || normalized === "yes";
}

async function encryptBatchInCurrentDb(limit, rotateToCurrentVersion) {
  const batchLimit = toPositiveInt(limit, 200);
  const encryptedLike = `${MESSAGE_ENCRYPTION_PREFIX}:%`;
  const currentVersion = getCurrentMessageKeyVersion();
  const rowsQ = await db.query(
    `SELECT id, text
     FROM messages
     WHERE text IS NOT NULL
       AND BTRIM(text) <> ''
       AND (
         text NOT LIKE $1
         OR (
           $2::boolean = true
           AND text LIKE $1
           AND split_part(text, ':', 2) <> $3
         )
       )
     ORDER BY created_at ASC, id ASC
     LIMIT $4`,
    [encryptedLike, rotateToCurrentVersion, currentVersion, batchLimit],
  );
  if (rowsQ.rowCount === 0) return { updated: 0, skipped: 0, failed: 0 };

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");
    let updated = 0;
    let skipped = 0;
    let failed = 0;
    for (const row of rowsQ.rows) {
      const raw = String(row.text || "");
      if (!raw) {
        skipped += 1;
        continue;
      }

      const alreadyEncrypted = isEncryptedMessageText(raw);
      const currentRowVersion = getEncryptedMessageVersion(raw);
      if (
        alreadyEncrypted &&
        (!rotateToCurrentVersion || currentRowVersion === currentVersion)
      ) {
        skipped += 1;
        continue;
      }

      let plain = raw;
      if (alreadyEncrypted) {
        plain = decryptMessageText(raw);
        if (!plain) {
          failed += 1;
          continue;
        }
      }

      const encrypted = encryptMessageText(plain, {
        force: true,
        version: currentVersion,
      });
      if (!encrypted || encrypted === raw) {
        skipped += 1;
        continue;
      }

      await client.query(
        `UPDATE messages
         SET text = $1
         WHERE id = $2`,
        [encrypted, row.id],
      );
      updated += 1;
    }
    await client.query("COMMIT");
    return { updated, skipped, failed };
  } catch (err) {
    try {
      await client.query("ROLLBACK");
    } catch (_) {}
    throw err;
  } finally {
    client.release();
  }
}

async function runBackfillForCurrentDb({
  label,
  batchSize,
  maxRows,
  rotateToCurrentVersion,
  logger = console,
}) {
  const safeBatch = toPositiveInt(batchSize, 200);
  const safeMaxRows = toPositiveInt(maxRows, 5000);
  let totalUpdated = 0;
  let totalSkipped = 0;
  let totalFailed = 0;
  while (totalUpdated < safeMaxRows) {
    const rest = safeMaxRows - totalUpdated;
    const currentLimit = rest < safeBatch ? rest : safeBatch;
    const stats = await encryptBatchInCurrentDb(
      currentLimit,
      rotateToCurrentVersion,
    );
    if (stats.updated <= 0) {
      totalSkipped += stats.skipped;
      totalFailed += stats.failed;
      break;
    }
    totalUpdated += stats.updated;
    totalSkipped += stats.skipped;
    totalFailed += stats.failed;
    if (stats.updated < currentLimit) break;
  }
  if (totalUpdated > 0 || totalFailed > 0) {
    logger.log(
      `[message-encryption] ${label}: updated=${totalUpdated}, skipped=${totalSkipped}, failed=${totalFailed}`,
    );
  }
  return { updated: totalUpdated, skipped: totalSkipped, failed: totalFailed };
}

async function runMessageEncryptionBackfill({ logger = console } = {}) {
  const disabled = String(
    process.env.MESSAGE_ENCRYPTION_BACKFILL_DISABLED || "",
  ).toLowerCase();
  if (disabled === "1" || disabled === "true" || disabled === "yes") {
    logger.log("[message-encryption] backfill disabled by env");
    return {
      platform: 0,
      isolated: 0,
      skipped: 0,
      failed: 0,
      scannedIsolated: 0,
    };
  }

  const rotateToCurrentVersion = toBool(
    process.env.MESSAGE_ENCRYPTION_ROTATE_TO_CURRENT,
    true,
  );
  const batchSize = toPositiveInt(
    process.env.MESSAGE_ENCRYPTION_BACKFILL_BATCH,
    200,
  );
  const maxRowsPerDatabase = toPositiveInt(
    process.env.MESSAGE_ENCRYPTION_BACKFILL_MAX_ROWS_PER_DB,
    5000,
  );

  let platformUpdated = 0;
  let isolatedUpdated = 0;
  let totalSkipped = 0;
  let totalFailed = 0;
  let scannedIsolated = 0;

  try {
    const platformStats = await db.runWithPlatform(() =>
      runBackfillForCurrentDb({
        label: "platform/shared",
        batchSize,
        maxRows: maxRowsPerDatabase,
        rotateToCurrentVersion,
        logger,
      }),
    );
    platformUpdated = platformStats.updated;
    totalSkipped += platformStats.skipped;
    totalFailed += platformStats.failed;
  } catch (err) {
    logger.error("[message-encryption] platform backfill error", err);
  }

  try {
    const tenantsQ = await db.platformQuery(
      `SELECT id, code, name, db_mode, db_url
       FROM tenants
       WHERE status = 'active'
         AND lower(coalesce(db_mode, '')) = 'isolated'
         AND coalesce(db_url, '') <> ''`,
    );
    for (const tenant of tenantsQ.rows) {
      scannedIsolated += 1;
      try {
        const stats = await db.runWithTenantRow(tenant, () =>
          runBackfillForCurrentDb({
            label: `tenant:${tenant.code || tenant.id}`,
            batchSize,
            maxRows: maxRowsPerDatabase,
            rotateToCurrentVersion,
            logger,
          }),
        );
        isolatedUpdated += stats.updated;
        totalSkipped += stats.skipped;
        totalFailed += stats.failed;
      } catch (tenantErr) {
        logger.error(
          `[message-encryption] tenant backfill error (${tenant.code || tenant.id})`,
          tenantErr,
        );
      }
    }
  } catch (err) {
    logger.error("[message-encryption] isolated tenants discovery error", err);
  }

  logger.log(
    `[message-encryption] backfill complete: platform=${platformUpdated}, isolated=${isolatedUpdated}, skipped=${totalSkipped}, failed=${totalFailed}, isolated_dbs=${scannedIsolated}`,
  );
  return {
    platform: platformUpdated,
    isolated: isolatedUpdated,
    skipped: totalSkipped,
    failed: totalFailed,
    scannedIsolated,
  };
}

module.exports = {
  runMessageEncryptionBackfill,
};
