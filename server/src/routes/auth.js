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
  generateInviteCode,
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

function extractTenantCodeHint(req) {
  const fromHeader = String(req.get('x-tenant-code') || '').trim();
  if (fromHeader) return db.normalizeTenantCode(fromHeader);

  const fromBody = String(req.body?.tenant_code || '').trim();
  if (fromBody) return db.normalizeTenantCode(fromBody);

  const fromQuery = String(req.query?.tenant || req.query?.tenant_code || '').trim();
  if (fromQuery) return db.normalizeTenantCode(fromQuery);

  return '';
}

function buildInviteLink(req, inviteCode, tenantCode = '') {
  const base = String(process.env.INVITE_LINK_BASE || '').trim();
  const encodedInvite = encodeURIComponent(String(inviteCode || '').trim());
  const encodedTenant = encodeURIComponent(String(tenantCode || '').trim());
  const tenantPart = encodedTenant ? `&tenant=${encodedTenant}` : '';
  if (base) {
    const glue = base.includes('?') ? '&' : '?';
    return `${base}${glue}invite=${encodedInvite}${tenantPart}`;
  }
  return `${req.protocol}://${req.get('host')}/?invite=${encodedInvite}${tenantPart}`;
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

async function resolveTenantByAccessKey(accessKey) {
  const normalized = normalizeAccessKey(accessKey);
  if (!normalized) return null;
  const hash = hashAccessKey(normalized);
  const tenantRes = await db.platformQuery(
    `SELECT id, code, name, status, subscription_expires_at,
            db_mode, db_url, db_name
     FROM tenants
     WHERE access_key_hash = $1
     LIMIT 1`,
    [hash],
  );
  return tenantRes.rowCount > 0 ? tenantRes.rows[0] : null;
}

async function resolveTenantInviteByCode(inviteCode) {
  const normalized = normalizeInviteCode(inviteCode);
  if (!normalized) return null;
  const inviteRes = await db.platformQuery(
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
            t.subscription_expires_at,
            t.db_mode,
            t.db_url,
            t.db_name
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

    const tenantCodeHint = extractTenantCodeHint(req);
    const existing = tenantCodeHint
      ? await db.runWithTenantCode(
          tenantCodeHint,
          () => db.query('SELECT 1 FROM users WHERE email = $1', [normalizedEmail]),
        )
      : await db.platformQuery('SELECT 1 FROM users WHERE email = $1', [normalizedEmail]);
    return res.json({ exists: existing.rowCount > 0 });
  } catch (err) {
    if (String(err?.code || '') === 'TENANT_NOT_FOUND') {
      return res.status(404).json({ exists: false, error: 'Арендатор не найден' });
    }
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

    let role = 'client';
    let tenant = null;
    let invite = null;
    const isPlatformCreator = normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase();

    if (isPlatformCreator) {
      if (typeof secret !== 'string' || secret !== CREATOR_SECRET) {
        return res.status(403).json({ error: 'Invalid secret for this email' });
      }
      role = 'creator';
    } else {
      const rawInputCode = String(access_key || '').trim();
      const rawAccessKey = normalizeAccessKey(rawInputCode);
      const rawInviteCode = normalizeInviteCode(invite_code || access_key);
      const looksLikeAccessKey = rawAccessKey.startsWith('PHX');

      if (looksLikeAccessKey) {
        tenant = await resolveTenantByAccessKey(rawAccessKey);
        if (!tenant) {
          return res.status(403).json({ error: 'Неверный ключ арендатора.' });
        }
        role = 'admin';
      } else if (rawInviteCode) {
        invite = await resolveTenantInviteByCode(rawInviteCode);
        if (!invite) {
          return res.status(403).json({ error: 'Неверный или устаревший код приглашения.' });
        }
        if (invite.is_active !== true) {
          return res.status(403).json({ error: 'Код приглашения отключен.' });
        }
        if (invite.expires_at && new Date(invite.expires_at).getTime() < Date.now()) {
          return res.status(403).json({ error: 'Срок действия кода приглашения истек.' });
        }
        const maxUses = Number(invite.max_uses);
        const usedCount = Number(invite.used_count || 0);
        if (Number.isFinite(maxUses) && maxUses > 0 && usedCount >= maxUses) {
          return res.status(403).json({ error: 'Лимит использований этого кода приглашения исчерпан.' });
        }
        tenant = {
          id: invite.tenant_id,
          code: invite.tenant_code,
          name: invite.tenant_name,
          status: invite.status,
          subscription_expires_at: invite.subscription_expires_at,
          db_mode: invite.db_mode || 'shared',
          db_url: invite.db_url || null,
          db_name: invite.db_name || null,
        };
        const invitedRole = String(invite.role || 'client').toLowerCase().trim();
        role = invitedRole === 'worker' || invitedRole === 'admin' ? invitedRole : 'client';
      } else {
        return res.status(403).json({
          error:
            'Для регистрации нужен ключ арендатора (для владельца) или код приглашения (для сотрудника/клиента).',
        });
      }

      const tenantState = isTenantActive(tenant);
      if (!tenantState.ok) {
        return res.status(403).json({ error: tenantState.error });
      }
    }

    const registerInScope = async () => {
      const client = await db.pool.connect();
      try {
        await client.query('BEGIN');

        const existing = await client.query('SELECT id FROM users WHERE email = $1', [normalizedEmail]);
        if (existing.rowCount > 0) {
          await client.query('ROLLBACK');
          return { ok: false, status: 409, error: 'Email already registered' };
        }

        await assertDeviceAccountLimit(client, device_fingerprint);

        const password_hash = await bcrypt.hash(password, SALT_ROUNDS);
        const insertUser = await client.query(
          `INSERT INTO users (email, password_hash, name, role, tenant_id, created_at)
           VALUES ($1, $2, $3, $4, $5, now())
           RETURNING id, email, name, role, tenant_id`,
          [
            normalizedEmail,
            password_hash,
            name || null,
            role,
            isPlatformCreator ? null : tenant?.id || null,
          ],
        );
        const user = insertUser.rows[0];

        if (phone) {
          const normalizedPhone = String(phone).replace(/\D/g, '');
          if (normalizedPhone.length < 10) {
            await client.query('ROLLBACK');
            return { ok: false, status: 400, error: 'Invalid phone format' };
          }
          await client.query(
            `INSERT INTO phones (user_id, phone, status, created_at)
             VALUES ($1, $2, 'pending_verification', now())
             ON CONFLICT (user_id) DO UPDATE
               SET phone = $2, status = 'pending_verification', created_at = now()`,
            [user.id, normalizedPhone],
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
        return { ok: true, user, sessionId };
      } catch (err) {
        try { await client.query('ROLLBACK'); } catch (_) {}
        throw err;
      } finally {
        client.release();
      }
    };

    const registration = await db.runWithTenantRow(
      isPlatformCreator ? null : tenant,
      registerInScope,
    );
    if (!registration?.ok) {
      return res.status(registration?.status || 500).json({
        error: registration?.error || 'Internal server error',
      });
    }

    if (invite?.id) {
      try {
        await db.platformQuery(
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
      } catch (err) {
        console.error('auth.register invite usage update error', err);
      }
    }

    const token = signToken({
      id: registration.user.id,
      email: registration.user.email,
      role: registration.user.role,
      tenant_id: registration.user.tenant_id || null,
      tenant_code: tenant?.code || null,
      sid: registration.sessionId,
    });

    return res.status(201).json({
      token,
      session_id: registration.sessionId,
      user: {
        id: registration.user.id,
        email: registration.user.email,
        name: registration.user.name,
        role: registration.user.role,
        tenant_id: registration.user.tenant_id || null,
        tenant_code: tenant?.code || null,
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
    console.error('auth.register error', err);
    return res.status(err.statusCode || 500).json({ error: err.message || 'Internal server error' });
  }
});

/**
 * POST /api/auth/login
 * body: { email, password }
 *
 * Returns { token, user: { id, email, role } }
 */
router.post('/login', async (req, res) => {
  try {
    const { email, password, device_fingerprint, access_key } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Неверный логин или пароль' });
    }

    const isPlatformCreator = normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase();
    let tenant = null;

    if (!isPlatformCreator) {
      const tenantCodeHint = extractTenantCodeHint(req);
      if (tenantCodeHint) {
        tenant = await db.resolveTenantByCode(tenantCodeHint);
      } else {
        const normalizedAccessKey = normalizeAccessKey(access_key);
        if (normalizedAccessKey.startsWith('PHX')) {
          tenant = await resolveTenantByAccessKey(normalizedAccessKey);
        }
      }

      if (!tenant) {
        return res.status(400).json({
          error:
            'Не определен арендатор. Войдите по приглашению вашей группы или укажите код арендатора.',
        });
      }
      const tenantState = isTenantActive(tenant);
      if (!tenantState.ok) {
        return res.status(403).json({ error: tenantState.error });
      }
    }

    const loginInScope = async () => {
      const client = await db.pool.connect();
      try {
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
          return { ok: false, status: 401, error: 'Неверные данные' };
        }

        const ok = await bcrypt.compare(password, user.password_hash);
        if (!ok) {
          await client.query('ROLLBACK');
          return { ok: false, status: 401, error: 'Неверные данные' };
        }

        if (!isPlatformCreator) {
          if (!user.tenant_id) {
            await client.query('ROLLBACK');
            return {
              ok: false,
              status: 403,
              error: 'Аккаунт не привязан к арендатору. Обратитесь к владельцу приложения.',
            };
          }
          const tenantState = isTenantActive({
            status: user.tenant_status || tenant?.status,
            subscription_expires_at:
              user.subscription_expires_at || tenant?.subscription_expires_at,
          });
          if (!tenantState.ok) {
            await client.query('ROLLBACK');
            return { ok: false, status: 403, error: tenantState.error };
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
        return { ok: true, user, sessionId };
      } catch (err) {
        try { await client.query('ROLLBACK'); } catch (_) {}
        throw err;
      } finally {
        client.release();
      }
    };

    const result = await db.runWithTenantRow(
      isPlatformCreator ? null : tenant,
      loginInScope,
    );
    if (!result?.ok) {
      return res.status(result?.status || 500).json({
        error: result?.error || 'Internal server error',
      });
    }

    const effectiveTenantCode = isPlatformCreator
      ? null
      : tenant?.code || result.user.tenant_code || null;
    const token = signToken({
      id: result.user.id,
      email: result.user.email,
      role: result.user.role,
      tenant_id: result.user.tenant_id || null,
      tenant_code: effectiveTenantCode,
      sid: result.sessionId,
    });
    return res.json({
      token,
      session_id: result.sessionId,
      user: {
        id: result.user.id,
        email: result.user.email,
        role: result.user.role,
        tenant_id: result.user.tenant_id || null,
        tenant_code: effectiveTenantCode,
      },
      tenant: result.user.tenant_id
        ? {
            id: result.user.tenant_id,
            code: effectiveTenantCode,
            name: result.user.tenant_name || tenant?.name || null,
            subscription_expires_at:
              result.user.subscription_expires_at || tenant?.subscription_expires_at || null,
          }
        : null,
    });
  } catch (err) {
    console.error('auth.login error', err);
    return res.status(err.statusCode || 500).json({ error: err.message || 'Internal server error' });
  }
});

router.get('/tenant/public-invite', authMiddleware, async (req, res) => {
  try {
    if (req.user?.is_platform_creator === true) {
      return res.status(403).json({
        ok: false,
        error: 'Для создателя ссылка приглашения не требуется',
      });
    }

    const tenantId = String(req.user?.tenant_id || '').trim();
    const tenantCode = String(req.user?.tenant_code || '').trim();
    if (!tenantId || !tenantCode) {
      return res.status(403).json({
        ok: false,
        error: 'Аккаунт не привязан к арендатору',
      });
    }

    const existing = await db.platformQuery(
      `SELECT id, code, is_active, max_uses, used_count, expires_at
       FROM tenant_invites
       WHERE tenant_id = $1
         AND role = 'client'
         AND is_active = true
         AND (expires_at IS NULL OR expires_at > now())
         AND (max_uses IS NULL OR used_count < max_uses)
       ORDER BY created_at DESC
       LIMIT 1`,
      [tenantId],
    );

    let inviteCode = '';
    let inviteId = '';

    if (existing.rowCount > 0) {
      inviteCode = String(existing.rows[0].code || '').trim();
      inviteId = String(existing.rows[0].id || '').trim();
    } else {
      let created = null;
      for (let i = 0; i < 5; i += 1) {
        const code = normalizeInviteCode(generateInviteCode());
        try {
          const insert = await db.platformQuery(
            `INSERT INTO tenant_invites (
               id, tenant_id, code, role, is_active, max_uses,
               used_count, expires_at, created_by, notes, created_at, updated_at
             )
             VALUES (
               $1, $2, $3, 'client', true, NULL,
               0, NULL, $4, 'Публичная клиентская ссылка', now(), now()
             )
             RETURNING id, code`,
            [uuidv4(), tenantId, code, req.user.id],
          );
          created = insert.rows[0];
          break;
        } catch (err) {
          if (String(err?.code || '') === '23505') continue;
          throw err;
        }
      }
      if (!created) {
        return res.status(500).json({
          ok: false,
          error: 'Не удалось создать ссылку приглашения',
        });
      }
      inviteCode = String(created.code || '').trim();
      inviteId = String(created.id || '').trim();
    }

    return res.json({
      ok: true,
      data: {
        invite_id: inviteId,
        code: inviteCode,
        tenant_code: tenantCode,
        invite_link: buildInviteLink(req, inviteCode, tenantCode),
      },
    });
  } catch (err) {
    console.error('auth.tenant.publicInvite error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
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
