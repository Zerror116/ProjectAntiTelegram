const { v4: uuidv4 } = require('uuid');

function normalizePhoneDigits(raw) {
  return String(raw || '').replace(/\D/g, '').slice(0, 20);
}

function normalizeDecision(raw) {
  const value = String(raw || '').trim().toLowerCase();
  if (value === 'approve' || value === 'approved' || value === 'allow') {
    return 'approved';
  }
  if (value === 'reject' || value === 'rejected' || value === 'deny') {
    return 'rejected';
  }
  return '';
}

async function findOldestPhoneOwner(
  queryable,
  { tenantId = null, phoneDigits = '', excludeUserId = null } = {},
) {
  const normalizedPhone = normalizePhoneDigits(phoneDigits);
  if (!tenantId || normalizedPhone.length < 10) return null;

  const ownerQ = await queryable.query(
    `SELECT u.id,
            u.email,
            u.name,
            p.phone,
            u.created_at
     FROM users u
     JOIN phones p ON p.user_id = u.id
     WHERE u.tenant_id = $1
       AND regexp_replace(COALESCE(p.phone, ''), '[^0-9]', '', 'g') = $2
       AND COALESCE(NULLIF(BTRIM(lower(u.role)), ''), 'client') = 'client'
       AND u.is_active = true
       AND ($3::uuid IS NULL OR u.id <> $3::uuid)
     ORDER BY u.created_at ASC
     LIMIT 1`,
    [tenantId, normalizedPhone, excludeUserId || null],
  );
  if (ownerQ.rowCount === 0) return null;
  return ownerQ.rows[0];
}

async function rebalancePendingPhoneRequestOwners(
  queryable,
  { tenantId = null } = {},
) {
  await queryable.query(
    `WITH pending_requests AS (
       SELECT r.id,
              r.tenant_id,
              r.phone,
              r.requester_user_id,
              r.owner_user_id,
              COALESCE(NULLIF(BTRIM(lower(owner_user.role)), ''), 'client') AS owner_role
       FROM phone_registration_requests r
       LEFT JOIN users owner_user ON owner_user.id = r.owner_user_id
       WHERE r.status = 'pending'
         AND ($1::uuid IS NULL OR r.tenant_id = $1::uuid)
     ),
     candidate_owner AS (
       SELECT pr.id AS request_id,
              owner.id AS owner_user_id,
              pr.owner_role
       FROM pending_requests pr
       LEFT JOIN LATERAL (
         SELECT u.id
         FROM users u
         JOIN phones p ON p.user_id = u.id
         WHERE u.tenant_id = pr.tenant_id
           AND regexp_replace(COALESCE(p.phone, ''), '[^0-9]', '', 'g') = pr.phone
           AND COALESCE(NULLIF(BTRIM(lower(u.role)), ''), 'client') = 'client'
           AND u.is_active = true
           AND u.id <> pr.requester_user_id
         ORDER BY u.created_at ASC
         LIMIT 1
       ) owner ON true
     ),
     reassign AS (
       UPDATE phone_registration_requests r
       SET owner_user_id = c.owner_user_id
       FROM candidate_owner c
       WHERE r.id = c.request_id
         AND c.owner_user_id IS NOT NULL
         AND r.owner_user_id <> c.owner_user_id
       RETURNING r.id
     ),
     auto_approve AS (
       UPDATE phone_registration_requests r
       SET status = 'approved',
           decided_at = now(),
           decided_by = NULL,
           note = 'auto-approved: no existing client owner'
       FROM candidate_owner c
       WHERE r.id = c.request_id
         AND c.owner_user_id IS NULL
         AND c.owner_role <> 'client'
         AND r.status = 'pending'
       RETURNING r.id
     )
     SELECT
       (SELECT COUNT(*)::int FROM reassign) AS reassigned_count,
       (SELECT COUNT(*)::int FROM auto_approve) AS auto_approved_count`,
    [tenantId || null],
  );
}

async function createPhoneAccessRequest(
  queryable,
  {
    tenantId = null,
    phoneDigits = '',
    ownerUserId = '',
    requesterUserId = '',
  } = {},
) {
  const normalizedPhone = normalizePhoneDigits(phoneDigits);
  const ownerId = String(ownerUserId || '').trim();
  const requesterId = String(requesterUserId || '').trim();
  if (
    !tenantId ||
    normalizedPhone.length < 10 ||
    !ownerId ||
    !requesterId ||
    ownerId === requesterId
  ) {
    return null;
  }

  const existingPendingQ = await queryable.query(
    `SELECT id,
            tenant_id,
            phone,
            owner_user_id,
            requester_user_id,
            status,
            requested_at,
            decided_at,
            decided_by
     FROM phone_registration_requests
     WHERE tenant_id = $1
       AND owner_user_id = $2
       AND requester_user_id = $3
       AND phone = $4
       AND status = 'pending'
     ORDER BY requested_at DESC
     LIMIT 1`,
    [tenantId, ownerId, requesterId, normalizedPhone],
  );
  if (existingPendingQ.rowCount > 0) {
    return existingPendingQ.rows[0];
  }

  const insertQ = await queryable.query(
    `INSERT INTO phone_registration_requests (
       id,
       tenant_id,
       phone,
       owner_user_id,
       requester_user_id,
       status,
       requested_at
     )
     VALUES ($1, $2, $3, $4, $5, 'pending', now())
     RETURNING id,
               tenant_id,
               phone,
               owner_user_id,
               requester_user_id,
               status,
               requested_at,
               decided_at,
               decided_by`,
    [uuidv4(), tenantId, normalizedPhone, ownerId, requesterId],
  );
  return insertQ.rows[0] || null;
}

async function resolvePhoneAccessState(
  queryable,
  { requesterUserId = '', tenantId = null } = {},
) {
  const requesterId = String(requesterUserId || '').trim();
  if (!requesterId) {
    return { state: 'none' };
  }

  const stateQ = await queryable.query(
    `SELECT r.id,
            r.tenant_id,
            r.phone,
            r.owner_user_id,
            r.requester_user_id,
            r.status,
            r.requested_at,
            r.decided_at,
            r.decided_by,
            owner.name AS owner_name,
            owner.email AS owner_email
     FROM phone_registration_requests r
     LEFT JOIN users owner ON owner.id = r.owner_user_id
     WHERE r.requester_user_id = $1
       AND ($2::uuid IS NULL OR r.tenant_id = $2::uuid)
     ORDER BY CASE r.status
                WHEN 'pending' THEN 0
                WHEN 'approved' THEN 1
                WHEN 'rejected' THEN 2
                ELSE 3
              END,
              r.requested_at DESC
     LIMIT 1`,
    [requesterId, tenantId || null],
  );
  if (stateQ.rowCount === 0) {
    return { state: 'none' };
  }

  const row = stateQ.rows[0];
  const state = String(row.status || '').trim().toLowerCase();
  const base = {
    state,
    request_id: row.id,
    tenant_id: row.tenant_id || null,
    phone: row.phone || '',
    owner_user_id: row.owner_user_id || null,
    owner_name: row.owner_name || '',
    owner_email: row.owner_email || '',
    requested_at: row.requested_at || null,
    decided_at: row.decided_at || null,
  };
  if (state === 'approved') {
    return {
      ...base,
      shared_cart_owner_id: row.owner_user_id || null,
      message: 'Доступ к корзине предоставлен',
    };
  }
  if (state === 'rejected') {
    return {
      ...base,
      message: 'Владелец номера отклонил запрос на общий доступ',
    };
  }
  if (state === 'pending') {
    return {
      ...base,
      message: 'Ожидается решение первого владельца номера',
    };
  }
  return { state: 'none' };
}

async function resolveSharedCartOwnerId(
  queryable,
  { requesterUserId = '', tenantId = null } = {},
) {
  const state = await resolvePhoneAccessState(queryable, {
    requesterUserId,
    tenantId,
  });
  if (
    state.state === 'approved' &&
    String(state.shared_cart_owner_id || '').trim()
  ) {
    return String(state.shared_cart_owner_id).trim();
  }
  return String(requesterUserId || '').trim();
}

async function listPendingPhoneAccessRequestsForOwner(
  queryable,
  { ownerUserId = '', tenantId = null } = {},
) {
  const ownerId = String(ownerUserId || '').trim();
  if (!ownerId) return [];
  const rowsQ = await queryable.query(
    `SELECT r.id,
            r.tenant_id,
            r.phone,
            r.owner_user_id,
            r.requester_user_id,
            r.status,
            r.requested_at,
            requester.name AS requester_name,
            requester.email AS requester_email
     FROM phone_registration_requests r
     JOIN users requester ON requester.id = r.requester_user_id
     WHERE r.owner_user_id = $1
       AND r.status = 'pending'
       AND ($2::uuid IS NULL OR r.tenant_id = $2::uuid)
     ORDER BY r.requested_at DESC`,
    [ownerId, tenantId || null],
  );
  return rowsQ.rows || [];
}

async function decidePhoneAccessRequest(
  queryable,
  {
    requestId = '',
    ownerUserId = '',
    tenantId = null,
    decision = '',
    note = '',
  } = {},
) {
  const id = String(requestId || '').trim();
  const ownerId = String(ownerUserId || '').trim();
  const normalizedDecision = normalizeDecision(decision);
  if (!id || !ownerId || !normalizedDecision) {
    return { ok: false, status: 400, error: 'Некорректные данные решения' };
  }

  const requestQ = await queryable.query(
    `SELECT id,
            tenant_id,
            phone,
            owner_user_id,
            requester_user_id,
            status,
            requested_at,
            decided_at,
            decided_by
     FROM phone_registration_requests
     WHERE id = $1
       AND owner_user_id = $2
       AND ($3::uuid IS NULL OR tenant_id = $3::uuid)
     LIMIT 1
     FOR UPDATE`,
    [id, ownerId, tenantId || null],
  );
  if (requestQ.rowCount === 0) {
    return { ok: false, status: 404, error: 'Запрос не найден' };
  }
  const request = requestQ.rows[0];
  if (String(request.status || '') !== 'pending') {
    return {
      ok: false,
      status: 400,
      error: 'По этому запросу решение уже принято',
    };
  }

  const updateQ = await queryable.query(
    `UPDATE phone_registration_requests
     SET status = $2,
         decided_at = now(),
         decided_by = $3,
         note = NULLIF(BTRIM($4::text), '')
     WHERE id = $1
     RETURNING id,
               tenant_id,
               phone,
               owner_user_id,
               requester_user_id,
               status,
               requested_at,
               decided_at,
               decided_by,
               note`,
    [id, normalizedDecision, ownerId, String(note || '').slice(0, 500)],
  );
  return { ok: true, row: updateQ.rows[0] || null };
}

module.exports = {
  normalizePhoneDigits,
  normalizeDecision,
  findOldestPhoneOwner,
  createPhoneAccessRequest,
  rebalancePendingPhoneRequestOwners,
  resolvePhoneAccessState,
  resolveSharedCartOwnerId,
  listPendingPhoneAccessRequestsForOwner,
  decidePhoneAccessRequest,
};
