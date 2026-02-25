// server/src/routes/setup.js
const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

function parseDatabaseUrl(dbUrl) {
  const url = new URL(dbUrl);
  const targetDbName = (url.pathname || '').replace(/^\//, '') || 'postgres';
  const adminUrl = new URL(dbUrl);
  adminUrl.pathname = '/postgres';
  return { adminUrl: adminUrl.toString(), targetUrl: dbUrl, targetDbName };
}

async function ensureDatabaseExists(dbUrl) {
  const { adminUrl, targetUrl, targetDbName } = parseDatabaseUrl(dbUrl);

  // Попытка подключиться к целевой БД
  let targetPool = new Pool({ connectionString: targetUrl });
  try {
    await targetPool.query('SELECT 1');
    await targetPool.end();
    return { created: false, targetUrl, targetDbName };
  } catch (err) {
    await targetPool.end();
    // Подключаемся к admin (postgres) и создаём БД, если её нет
    const adminPool = new Pool({ connectionString: adminUrl });
    try {
      const existsRes = await adminPool.query('SELECT 1 FROM pg_database WHERE datname = $1', [targetDbName]);
      if (existsRes.rowCount === 0) {
        await adminPool.query(`CREATE DATABASE "${targetDbName}"`);
      }
      await adminPool.end();
      return { created: true, targetUrl, targetDbName };
    } catch (createErr) {
      await adminPool.end();
      throw createErr;
    }
  }
}

async function applyMigrationsToTarget(dbUrl, migrationsDir) {
  const pool = new Pool({ connectionString: dbUrl });
  try {
    // Проверяем, инициализирована ли база (наличие таблицы users)
    const check = await pool.query(`SELECT to_regclass('public.users') as exists`);
    const exists = check.rows[0] && check.rows[0].exists;
    if (exists) {
      await pool.end();
      return { applied: [], message: 'Already initialized' };
    }

    if (!fs.existsSync(migrationsDir)) {
      await pool.end();
      throw new Error('Migrations folder not found: ' + migrationsDir);
    }

    // Читаем все .sql файлы и сортируем по имени (лексикографически)
    const files = fs.readdirSync(migrationsDir).filter(f => f.endsWith('.sql')).sort();
    if (files.length === 0) {
      await pool.end();
      return { applied: [], message: 'No migration files found' };
    }

    // Выполняем миграции в одной транзакции
    await pool.query('BEGIN');
    const applied = [];
    for (const file of files) {
      const filePath = path.join(migrationsDir, file);
      const sql = fs.readFileSync(filePath, 'utf8');
      // Выполняем SQL. Если файл содержит несколько команд — pg client выполнит их.
      await pool.query(sql);
      applied.push(file);
      console.log('Applied migration:', file);
    }
    await pool.query('COMMIT');

    await pool.end();
    return { applied, message: 'Migrations applied' };
  } catch (err) {
    try { await pool.query('ROLLBACK'); } catch (_) {}
    await pool.end();
    throw err;
  }
}

router.post('/', async (req, res) => {
  try {
    const dbUrl = process.env.DATABASE_URL || 'postgresql://antitelegram:antitelegram@localhost:5432/antitelegram';
    const dbResult = await ensureDatabaseExists(dbUrl);

    // Путь к папке migrations относительно этого файла
    const migrationsDir = path.resolve(__dirname, '../../migrations');

    const migResult = await applyMigrationsToTarget(dbUrl, migrationsDir);

    return res.json({
      ok: true,
      dbCreated: dbResult.created,
      dbName: dbResult.targetDbName,
      applied: migResult.applied,
      message: migResult.message || 'Migrations applied'
    });
  } catch (err) {
    console.error('Setup error:', err);
    return res.status(500).json({ ok: false, error: String(err) });
  }
});

module.exports = router;
