const fs = require("fs");
const path = require("path");
const { Pool } = require("pg");

const db = require("../db");
const { ensureSystemChannels } = require("./systemChannels");

function parseDatabaseUrl(dbUrl) {
  const url = new URL(dbUrl);
  const targetDbName = (url.pathname || "").replace(/^\//, "") || "postgres";
  const adminUrl = new URL(dbUrl);
  adminUrl.pathname = "/postgres";
  return { adminUrl: adminUrl.toString(), targetUrl: dbUrl, targetDbName };
}

async function ensureDatabaseExists(dbUrl) {
  const { adminUrl, targetUrl, targetDbName } = parseDatabaseUrl(dbUrl);

  const targetPool = new Pool({ connectionString: targetUrl });
  try {
    await targetPool.query("SELECT 1");
    await targetPool.end();
    return { created: false, targetUrl, targetDbName };
  } catch (_) {
    await targetPool.end();

    const adminPool = new Pool({ connectionString: adminUrl });
    try {
      const existsRes = await adminPool.query(
        "SELECT 1 FROM pg_database WHERE datname = $1",
        [targetDbName],
      );
      if (existsRes.rowCount === 0) {
        const safeDbName = targetDbName.replace(/"/g, '""');
        await adminPool.query(`CREATE DATABASE "${safeDbName}"`);
      }
      await adminPool.end();
      return { created: true, targetUrl, targetDbName };
    } catch (createErr) {
      await adminPool.end();
      throw createErr;
    }
  }
}

async function ensureSchemaMigrationsTable(pool) {
  await pool.query(
    `CREATE TABLE IF NOT EXISTS schema_migrations (
      filename TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )`,
  );
}

async function applyMigrationsToTarget(dbUrl, migrationsDir) {
  const pool = new Pool({ connectionString: dbUrl });
  try {
    if (!fs.existsSync(migrationsDir)) {
      throw new Error(`Migrations folder not found: ${migrationsDir}`);
    }

    const files = fs
      .readdirSync(migrationsDir)
      .filter((f) => f.endsWith(".sql"))
      .sort();

    if (files.length === 0) {
      return { applied: [], message: "No migration files found" };
    }

    await ensureSchemaMigrationsTable(pool);
    const appliedRes = await pool.query("SELECT filename FROM schema_migrations");
    const alreadyApplied = new Set(appliedRes.rows.map((r) => r.filename));

    const appliedNow = [];
    for (const file of files) {
      if (alreadyApplied.has(file)) continue;

      const filePath = path.join(migrationsDir, file);
      const sql = fs.readFileSync(filePath, "utf8");

      await pool.query("BEGIN");
      try {
        await pool.query(sql);
        await pool.query(
          "INSERT INTO schema_migrations (filename, applied_at) VALUES ($1, now())",
          [file],
        );
        await pool.query("COMMIT");
        appliedNow.push(file);
      } catch (err) {
        await pool.query("ROLLBACK");
        throw err;
      }
    }

    return {
      applied: appliedNow,
      message: appliedNow.length
        ? "Pending migrations applied"
        : "No pending migrations",
    };
  } finally {
    await pool.end();
  }
}

async function ensureSystemChannelsReady(createdBy = null) {
  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");
    const ensured = await ensureSystemChannels(client, createdBy);
    await client.query("COMMIT");
    return {
      main_channel_id: ensured.mainChannel.id,
      reserved_channel_id: ensured.reservedChannel.id,
      created: ensured.created,
    };
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

async function bootstrapDatabase({
  dbUrl = process.env.DATABASE_URL ||
    "postgresql://antitelegram:antitelegram@localhost:5432/antitelegram",
  migrationsDir = path.resolve(__dirname, "../../migrations"),
  createdBy = null,
} = {}) {
  const dbResult = await ensureDatabaseExists(dbUrl);
  const migResult = await applyMigrationsToTarget(dbUrl, migrationsDir);
  const systemChannels = await ensureSystemChannelsReady(createdBy);

  return {
    ok: true,
    dbCreated: dbResult.created,
    dbName: dbResult.targetDbName,
    applied: migResult.applied,
    message: migResult.message,
    systemChannels,
  };
}

module.exports = {
  parseDatabaseUrl,
  ensureDatabaseExists,
  ensureSchemaMigrationsTable,
  applyMigrationsToTarget,
  ensureSystemChannelsReady,
  bootstrapDatabase,
};
