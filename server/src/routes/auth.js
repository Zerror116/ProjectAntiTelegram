// server/src/routes/auth.js
const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const validator = require('validator');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const db = require('../db'); // предполагается, что db экспортирует функцию query
const { authMiddleware } = require('../utils/auth');
const {
  PLATFORM_CREATOR_EMAIL,
  normalizeAccessKey,
  normalizeInviteCode,
  hashAccessKey,
  isTenantActive,
} = require('../utils/tenants');
const {
  createUserSession,
  listUserSessions,
  revokeOtherUserSessions,
  revokeSessionByRecordId,
  revokeUserSession,
} = require('../utils/sessions');
require('dotenv').config();

const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || '10', 10);

// Настройки для Creator
const CREATOR_EMAIL = PLATFORM_CREATOR_EMAIL;
const CREATOR_SECRET = process.env.CREATOR_SECRET || 'Макарова Лиза';
const MAX_ACCOUNTS_PER_DEVICE = 2;

function signToken(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d' });
}

function buildSessionExpiry() {
  return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
}

function normalizeDeviceFingerprint(value) {
  const normalized = String(value || '').trim();
  return normalized ? normalized.slice(0, 255) : null;
}

async function assertDeviceAccountLimit(queryable, deviceFingerprint, userId = null) {
  const fingerprint = normalizeDeviceFingerprint(deviceFingerprint);
  if (!fingerprint) return;

  const usage = await queryable.query(
    `SELECT user_id::text AS user_id
     FROM devices
     WHERE device_fingerprint = $1
     GROUP BY user_id`,
    [fingerprint],
  );
  const userIds = usage.rows
    .map((row) => String(row.user_id || '').trim())
    .filter(Boolean);
  const uniqueUsers = new Set(userIds);
  if (userId) uniqueUsers.delete(String(userId));
  if (uniqueUsers.size >= MAX_ACCOUNTS_PER_DEVICE) {
    const error = new Error('На одном устройстве можно использовать максимум 2 аккаунта');
    error.statusCode = 403;
    throw error;
  }
}

async function upsertDevice(queryable, userId, deviceFingerprint) {
  const fingerprint = normalizeDeviceFingerprint(deviceFingerprint);
  if (!userId || !fingerprint) return null;
  const result = await queryable.query(
    `INSERT INTO devices (id, user_id, device_fingerprint, trusted, created_at, last_seen)
     VALUES (gen_random_uuid(), $1, $2, true, now(), now())
     ON CONFLICT (user_id, device_fingerprint) DO UPDATE
       SET trusted = true,
           last_seen = now()
     RETURNING id`,
    [userId, fingerprint],
  );
  return result.rows[0]?.id || null;
}

async function resolveTenantByAccessKey(queryable, accessKey) {
  const normalized = normalizeAccessKey(accessKey);
  if (!normalized) return null;
  const hash = hashAccessKey(normalized);
  const tenantRes = await queryable.query(
    `SELECT id, code, name, status, subscription_expires_at
     FROM tenants
     WHERE access_key_hash = $1
     LIMIT 1`,
    [hash],
  );
  return tenantRes.rowCount > 0 ? tenantRes.rows[0] : null;
}

async function resolveTenantInviteByCode(queryable, inviteCode) {
  const normalized = normalizeInviteCode(inviteCode);
  if (!normalized) return null;
  const inviteRes = await queryable.query(
    `SELECT i.id,
            i.tenant_id,
            i.code,
            i.role,
            i.is_active,
            i.max_uses,
            i.used_count,
            i.expires_at,
            t.code AS tenant_code,
            t.name AS tenant_name,
            t.status,
            t.subscription_expires_at
     FROM tenant_invites i
     JOIN tenants t ON t.id = i.tenant_id
     WHERE i.code = $1
     LIMIT 1
     FOR UPDATE`,
    [normalized],
  );
  if (inviteRes.rowCount === 0) return null;
  return inviteRes.rows[0];
}

/**
 * POST /api/auth/check_email
 * body: { email }
 */
router.post('/check_email', async (req, res) => {
  try {
    const { email } = req.body || {};
    if (!email) return res.status(400).json({ error: 'email required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email' });
    }

    const existing = await db.query('SELECT 1 FROM users WHERE email = $1', [normalizedEmail]);
    return res.json({ exists: existing.rowCount > 0 });
  } catch (err) {
    console.error('check_email error', err);
    return res.status(500).json({ error: 'Server error' });
  }
});

/**
 * POST /api/auth/register
 * body: { email, password, name?, phone?, secret? }
 *
 * Notes:
 * - If email equals CREATOR_EMAIL and correct secret provided, role becomes 'creator'
 * - Returns { token, user: { id, email, name, role } }
 */
router.post('/register', async (req, res) => {
  const client = await db.pool.connect();
  try {
    const {
      email,
      password,
      name,
      phone,
      secret,
      device_fingerprint,
      access_key,
      invite_code,
    } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }
    if (typeof password !== 'string' || password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    await client.query('BEGIN');

    const existing = await client.query('SELECT id FROM users WHERE email = $1', [normalizedEmail]);
    if (existing.rowCount > 0) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'Email already registered' });
    }

    let role = 'client';
    let tenant = null;
    let invite = null;
    const isPlatformCreator = normalizedEmail.toLowerCase() === CREATOR_EMAIL;
    if (normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase()) {
      if (typeof secret === 'string' && secret === CREATOR_SECRET) {
        role = 'creator';
      } else {
        await client.query('ROLLBACK');
        return res.status(403).json({ error: 'Invalid secret for this email' });
      }
    } else {
      const rawInputCode = String(access_key || '').trim();
      const rawAccessKey = normalizeAccessKey(rawInputCode);
      const rawInviteCode = normalizeInviteCode(invite_code || access_key);
      const looksLikeAccessKey = rawAccessKey.startsWith('PHX');
      if (looksLikeAccessKey) {
        tenant = await resolveTenantByAccessKey(client, rawAccessKey);
        if (!tenant) {
          await client.query('ROLLBACK');
          return res.status(403).json({
            error: 'Неверный ключ арендатора.',
          });
        }
        role = 'admin';
      } else if (rawInviteCode) {
        invite = await resolveTenantInviteByCode(client, rawInviteCode);
        if (!invite) {
          await client.query('ROLLBACK');
          return res.status(403).json({
            error: 'Неверный или устаревший код приглашения.',
          });
        }
        if (invite.is_active !== true) {
          await client.query('ROLLBACK');
          return res.status(403).json({
            error: 'Код приглашения отключен.',
          });
        }
        if (invite.expires_at && new Date(invite.expires_at).getTime() < Date.now()) {
          await client.query('ROLLBACK');
          return res.status(403).json({
            error: 'Срок действия кода приглашения истек.',
          });
        }
        const maxUses = Number(invite.max_uses);
        const usedCount = Number(invite.used_count || 0);
        if (Number.isFinite(maxUses) && maxUses > 0 && usedCount >= maxUses) {
          await client.query('ROLLBACK');
          return res.status(403).json({
            error: 'Лимит использований этого кода приглашения исчерпан.',
          });
        }
        tenant = {
          id: invite.tenant_id,
          code: invite.tenant_code,
          name: invite.tenant_name,
          status: invite.status,
          subscription_expires_at: invite.subscription_expires_at,
        };
        const invitedRole = String(invite.role || 'client').toLowerCase().trim();
        role = invitedRole === 'worker' || invitedRole === 'admin' ? invitedRole : 'client';
      } else {
        await client.query('ROLLBACK');
        return res.status(403).json({
          error:
            'Для регистрации нужен ключ арендатора (для владельца) или код приглашения (для сотрудника/клиента).',
        });
      }
      const tenantState = isTenantActive(tenant);
      if (!tenantState.ok) {
        await client.query('ROLLBACK');
        return res.status(403).json({ error: tenantState.error });
      }
    }

    await assertDeviceAccountLimit(client, device_fingerprint);

    const password_hash = await bcrypt.hash(password, SALT_ROUNDS);
    const insertUser = await client.query(
      `INSERT INTO users (email, password_hash, name, role, tenant_id, created_at)
       VALUES ($1, $2, $3, $4, $5, now())
       RETURNING id, email, name, role, tenant_id`,
      [normalizedEmail, password_hash, name || null, role, isPlatformCreator ? null : tenant?.id || null]
    );
    const user = insertUser.rows[0];

    if (invite?.id) {
      await client.query(
        `UPDATE tenant_invites
         SET used_count = used_count + 1,
             is_active = CASE
               WHEN max_uses IS NOT NULL AND used_count + 1 >= max_uses THEN false
               ELSE is_active
             END,
             last_used_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [invite.id],
      );
    }

    if (phone) {
      const normalizedPhone = String(phone).replace(/\D/g, '');
      if (normalizedPhone.length < 10) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Invalid phone format' });
      }
      await client.query(
        `INSERT INTO phones (user_id, phone, status, created_at)
         VALUES ($1, $2, 'pending_verification', now())
         ON CONFLICT (user_id) DO UPDATE SET phone = $2, status = 'pending_verification', created_at = now()`,
        [user.id, normalizedPhone]
      );
    }

    await upsertDevice(client, user.id, device_fingerprint);

    const sessionId = uuidv4();
    const sessionExpiresAt = buildSessionExpiry();
    await createUserSession({
      queryable: client,
      userId: user.id,
      sessionId,
      deviceFingerprint: device_fingerprint,
      userAgent: req.get('user-agent') || '',
      ipAddress:
        req.headers['x-forwarded-for']?.toString().split(',')[0]?.trim() ||
        req.ip ||
        '',
      expiresAt: sessionExpiresAt,
    });

    await client.query('COMMIT');

    const token = signToken({
      id: user.id,
      email: user.email,
      role: user.role,
      tenant_id: user.tenant_id || null,
      sid: sessionId,
    });

    return res.status(201).json({
      token,
      session_id: sessionId,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        role: user.role,
        tenant_id: user.tenant_id || null,
      },
      tenant: tenant
        ? {
            id: tenant.id,
            code: tenant.code,
            name: tenant.name,
            subscription_expires_at: tenant.subscription_expires_at,
          }
        : null,
    });
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    console.error('auth.register error', err);
    return res.status(err.statusCode || 500).json({ error: err.message || 'Internal server error' });
  } finally {
    client.release();
  }
});

/**
 * POST /api/auth/login
 * body: { email, password }
 *
 * Returns { token, user: { id, email, role } }
 */
router.post('/login', async (req, res) => {
  const client = await db.pool.connect();
  try {
    const { email, password, device_fingerprint } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Неверный логин или пароль' });
    }

    await client.query('BEGIN');

    const userRes = await client.query(
      `SELECT u.id, u.email, u.password_hash, u.role, u.tenant_id,
              t.code AS tenant_code, t.name AS tenant_name, t.status AS tenant_status,
              t.subscription_expires_at
       FROM users u
       LEFT JOIN tenants t ON t.id = u.tenant_id
       WHERE u.email = $1
       LIMIT 1`,
      [normalizedEmail],
    );
    const user = userRes.rows[0];
    if (!user) {
      await client.query('ROLLBACK');
      return res.status(401).json({ error: 'Неверные данные' });
    }

    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) {
      await client.query('ROLLBACK');
      return res.status(401).json({ error: 'Неверные данные' });
    }

    const isPlatformCreator = String(user.email || '').toLowerCase() === CREATOR_EMAIL;
    if (!isPlatformCreator) {
      if (!user.tenant_id) {
        await client.query('ROLLBACK');
        return res.status(403).json({
          error: 'Аккаунт не привязан к арендатору. Обратитесь к владельцу приложения.',
        });
      }
      const tenantState = isTenantActive({
        status: user.tenant_status,
        subscription_expires_at: user.subscription_expires_at,
      });
      if (!tenantState.ok) {
        await client.query('ROLLBACK');
        return res.status(403).json({ error: tenantState.error });
      }
    }

    await assertDeviceAccountLimit(client, device_fingerprint, user.id);
    await upsertDevice(client, user.id, device_fingerprint);

    const sessionId = uuidv4();
    const sessionExpiresAt = buildSessionExpiry();
    await createUserSession({
      queryable: client,
      userId: user.id,
      sessionId,
      deviceFingerprint: device_fingerprint,
      userAgent: req.get('user-agent') || '',
      ipAddress:
        req.headers['x-forwarded-for']?.toString().split(',')[0]?.trim() ||
        req.ip ||
        '',
      expiresAt: sessionExpiresAt,
    });

    await client.query('COMMIT');

    const token = signToken({
      id: user.id,
      email: user.email,
      role: user.role,
      tenant_id: user.tenant_id || null,
      sid: sessionId,
    });
    return res.json({
      token,
      session_id: sessionId,
      user: {
        id: user.id,
        email: user.email,
        role: user.role,
        tenant_id: user.tenant_id || null,
      },
      tenant: user.tenant_id
        ? {
            id: user.tenant_id,
            code: user.tenant_code || null,
            name: user.tenant_name || null,
            subscription_expires_at: user.subscription_expires_at || null,
          }
        : null,
    });
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    console.error('auth.login error', err);
    return res.status(err.statusCode || 500).json({ error: err.message || 'Internal server error' });
  } finally {
    client.release();
  }
});

router.post('/logout', authMiddleware, async (req, res) => {
  try {
    const currentSessionId = req.user?.session_id || null;
    if (currentSessionId) {
      await revokeUserSession({ queryable: db, sessionId: currentSessionId });
    }
    return res.json({ ok: true, message: 'Logged out' });
  } catch (err) {
    console.error('auth.logout error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/sessions', authMiddleware, async (req, res) => {
  try {
    const rows = await listUserSessions({
      queryable: db,
      userId: req.user.id,
      currentSessionId: req.user.session_id || null,
    });
    return res.json({ ok: true, data: rows });
  } catch (err) {
    console.error('auth.sessions.list error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.post('/sessions/revoke_others', authMiddleware, async (req, res) => {
  try {
    const revoked = await revokeOtherUserSessions({
      queryable: db,
      userId: req.user.id,
      sessionId: req.user.session_id || null,
    });
    return res.json({ ok: true, data: { revoked } });
  } catch (err) {
    console.error('auth.sessions.revoke_others error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.delete('/sessions/:id', authMiddleware, async (req, res) => {
  try {
    const sessionRecordId = String(req.params?.id || '').trim();
    if (!sessionRecordId) {
      return res.status(400).json({ ok: false, error: 'session id обязателен' });
    }
    const revoked = await revokeSessionByRecordId({
      queryable: db,
      userId: req.user.id,
      sessionRecordId,
    });
    if (!revoked) {
      return res.status(404).json({ ok: false, error: 'Сессия не найдена' });
    }
    return res.json({ ok: true });
  } catch (err) {
    console.error('auth.sessions.revoke error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

/**
 * POST /api/auth/delete_account (защищённый)
 * Удаляет текущий аккаунт пользователя.
 */
router.post('/delete_account', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const result = await db.query('DELETE FROM users WHERE id = $1 RETURNING id', [userId]);
    if (result.rowCount === 0) {
      return res.status(404).json({ ok: false, error: 'Пользователь не найден' });
    }
    return res.json({ ok: true });
  } catch (err) {
    console.error('auth.delete_account error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

/**
 * POST /api/auth/change_password (защищённый)
 */
router.post('/change_password', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const { oldPassword, newPassword } = req.body || {};
    if (!oldPassword || !newPassword || newPassword.length < 8) {
      return res.status(400).json({ error: 'Old and new password (min 8 chars) required' });
    }

    const { rows } = await db.query('SELECT password_hash FROM users WHERE id=$1', [userId]);
    if (!rows.length) return res.status(404).json({ error: 'Пользователь не найден' });

    const currentHash = rows[0].password_hash;
    const match = await bcrypt.compare(oldPassword, currentHash);
    if (!match) return res.status(403).json({ error: 'Старый пароль неверный' });

    const newHash = await bcrypt.hash(newPassword, SALT_ROUNDS);
    await db.query('UPDATE users SET password_hash=$1 WHERE id=$2', [newHash, userId]);

    return res.json({ ok: true, message: 'Пароль изменён' });
  } catch (err) {
    console.error('auth.change_password error', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

module.exports = router;
